//! OIDC/PKCE loopback sign-in and single-flight rotating credentials.
use super::transport::{self, Endpoint, Request, Transport};
use crate::{Error, ProviderFailure, Result, check_cancel, core::ProviderConnection};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD as B64};
use ring::{
    rand::{SecureRandom, SystemRandom},
    signature,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    sync::oneshot,
};
use tokio_util::{sync::CancellationToken, task::TaskTracker};
pub const CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
const REDIRECT: &str = "http://localhost:1455/auth/callback";
fn failure() -> Error {
    Error::Provider(ProviderFailure::Authentication)
}
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn token(value: &str) -> bool {
    !value.is_empty() && value.len() <= 32768 && value.bytes().all(|b| (0x21..=0x7e).contains(&b))
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Session {
    pub access_token: String,
    pub refresh_token: String,
    pub account_id: String,
    pub subject: String,
    pub expires_at: u64,
    #[serde(default)]
    pub requires_reconnect: bool,
}
impl Session {
    fn validate(&self) -> Result<()> {
        if !token(&self.access_token)
            || !token(&self.refresh_token)
            || !token(&self.account_id)
            || self.account_id.len() > 256
            || self.subject.is_empty()
            || self.subject.len() > 1024
            || self.expires_at == 0
        {
            return Err(failure());
        }
        if account(&self.access_token)? != self.account_id {
            return Err(failure());
        }
        Ok(())
    }
}
struct State {
    session: Option<Session>,
    blocked: bool,
}
pub struct Authentication {
    file: super::super::private_json::PrivateJson,
    state: Arc<Mutex<State>>,
    gate: Arc<tokio::sync::Mutex<()>>,
    environment: bool,
    transport: Arc<dyn Transport>,
    tasks: TaskTracker,
}
fn form(fields: &[(&str, &str)]) -> String {
    let mut serializer = reqwest::Url::parse("https://auth.openai.com/").unwrap();
    serializer
        .query_pairs_mut()
        .extend_pairs(fields.iter().copied());
    serializer.query().unwrap_or("").to_owned()
}
fn random() -> Result<String> {
    let mut bytes = [0u8; 32];
    SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| failure())?;
    Ok(B64.encode(bytes))
}
/// Presentation metadata only; never used to authorize or identify a session.
fn display_email(access: &str) -> Option<String> {
    let payload = access.split('.').nth(1)?;
    let claims: Value = serde_json::from_slice(&B64.decode(payload).ok()?).ok()?;
    claims["https://api.openai.com/profile"]["email"]
        .as_str()
        .filter(|email| !email.is_empty() && email.len() <= 320 && !email.chars().any(char::is_control))
        .map(str::to_owned)
}

pub fn account(access: &str) -> Result<String> {
    let parts: Vec<_> = access.split('.').collect();
    if parts.len() != 3 {
        return Err(failure());
    }
    let part = parts[1];
    let bytes = B64.decode(part).map_err(|_| failure())?;
    let claims: Value = serde_json::from_slice(&bytes).map_err(|_| failure())?;
    let account = claims["https://api.openai.com/auth"]["chatgpt_account_id"]
        .as_str()
        .ok_or_else(failure)?;
    if !token(account) || account.len() > 256 {
        return Err(failure());
    }
    Ok(account.to_owned())
}
/// Only accept identity after verifying RS256, exact issuer/audience/azp, times and nonce.
pub fn verify_identity(
    jwt: &str,
    nonce: &str,
    keys: &Value,
    at: u64,
) -> Result<(String, Option<String>)> {
    if jwt.len() > 32768 {
        return Err(failure());
    }
    let parts: Vec<_> = jwt.split('.').collect();
    if parts.len() != 3 {
        return Err(failure());
    }
    let decode = |part: &str| B64.decode(part).map_err(|_| failure());
    let header: Value = serde_json::from_slice(&decode(parts[0])?).map_err(|_| failure())?;
    if header["alg"] != "RS256" {
        return Err(failure());
    }
    let kid = header["kid"].as_str().ok_or_else(failure)?;
    let keys = keys["keys"]
        .as_array()
        .filter(|a| a.len() <= 64)
        .ok_or_else(failure)?;
    let matching: Vec<_> = keys
        .iter()
        .filter(|k| k["kid"] == kid && k["kty"] == "RSA")
        .collect();
    if matching.len() != 1 {
        return Err(failure());
    }
    let key = matching[0];
    if key.get("alg").is_some_and(|a| a != "RS256") || key.get("use").is_some_and(|u| u != "sig") {
        return Err(failure());
    }
    let n = decode(key["n"].as_str().ok_or_else(failure)?)?;
    let e = decode(key["e"].as_str().ok_or_else(failure)?)?;
    signature::RsaPublicKeyComponents { n: &n, e: &e }
        .verify(
            &signature::RSA_PKCS1_2048_8192_SHA256,
            format!("{}.{}", parts[0], parts[1]).as_bytes(),
            &decode(parts[2])?,
        )
        .map_err(|_| failure())?;
    let claims: Value = serde_json::from_slice(&decode(parts[1])?).map_err(|_| failure())?;
    let audience: Vec<&str> = match &claims["aud"] {
        Value::String(s) => vec![s],
        Value::Array(a) => a
            .iter()
            .map(|v| v.as_str().ok_or_else(failure))
            .collect::<Result<_>>()?,
        _ => return Err(failure()),
    };
    if claims["iss"] != "https://auth.openai.com"
        || !audience.contains(&CLIENT_ID)
        || (audience.len() > 1 && claims["azp"] != CLIENT_ID)
        || claims.get("azp").is_some_and(|v| v != CLIENT_ID)
        || claims["exp"].as_u64().is_none_or(|exp| exp <= at)
        || claims
            .get("nbf")
            .is_some_and(|v| v.as_u64().is_none_or(|n| n > at))
        || claims["nonce"] != nonce
    {
        return Err(failure());
    }
    let subject = claims["sub"]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 1024)
        .ok_or_else(failure)?
        .to_owned();
    let account = claims["https://api.openai.com/auth"]["chatgpt_account_id"]
        .as_str()
        .map(str::to_owned);
    Ok((subject, account))
}
impl Authentication {
    /// Environment session JSON is explicit and externally managed; it is never refreshed.
    pub async fn open(
        path: PathBuf,
        environment: Option<String>,
        transport: Arc<dyn Transport>,
    ) -> Result<Arc<Self>> {
        let file = super::super::private_json::PrivateJson::new(path)?;
        let external = environment.is_some();
        let session = if let Some(value) = environment {
            Some(serde_json::from_str::<Session>(&value).map_err(|_| failure())?)
        } else {
            file.load()
                .await?
                .get("openai")
                .cloned()
                .map(serde_json::from_value::<Session>)
                .transpose()
                .map_err(|_| failure())?
        };
        if let Some(session) = &session {
            session.validate()?;
        }
        Ok(Arc::new(Self {
            file,
            state: Arc::new(Mutex::new(State {
                session,
                blocked: false,
            })),
            gate: Arc::new(tokio::sync::Mutex::new(())),
            environment: external,
            transport,
            tasks: TaskTracker::new(),
        }))
    }
    pub fn metadata_identity(&self) -> Option<String> {
        let state = self.state.lock().unwrap();
        state
            .session
            .as_ref()
            .filter(|s| !state.blocked && !s.requires_reconnect)
            .map(super::identity)
    }
    pub fn connection(&self) -> ProviderConnection {
        let state = self.state.lock().unwrap();
        ProviderConnection {
            id: "openai".into(),
            name: "OpenAI (ChatGPT subscription)".into(),
            connected: state
                .session
                .as_ref()
                .is_some_and(|s| !s.requires_reconnect)
                && !state.blocked,
            source: if self.environment {
                "environment"
            } else {
                "json"
            }
            .into(),
            email: state.session.as_ref()
                .filter(|s| !state.blocked && !s.requires_reconnect)
                .and_then(|s| display_email(&s.access_token)),
            manageable: !self.environment && !state.blocked,
            blocked: state.blocked || state.session.as_ref().is_some_and(|s| s.requires_reconnect),
        }
    }
    async fn save(&self, session: Option<Session>) -> Result<()> {
        let result = self
            .file
            .update(
                "openai".into(),
                session.as_ref().map(serde_json::to_value).transpose()?,
            )
            .await;
        let mut state = self.state.lock().unwrap();
        if result.is_ok() {
            state.session = session;
        } else {
            state.blocked = true;
            state.session = None;
        }
        result
    }
    async fn exchange(&self, body: String) -> Result<Value> {
        transport::json(
            self.transport.as_ref(),
            Request {
                session_id: None,
                endpoint: Endpoint::Token,
                access: None,
                account: None,
                body: Some(body),
            },
            128 * 1024,
            CancellationToken::new(),
        )
        .await
    }
    fn replacement(value: &Value, current: Option<&Session>) -> Result<Session> {
        if value
            .get("token_type")
            .is_some_and(|v| v.as_str().is_none_or(|s| !s.eq_ignore_ascii_case("bearer")))
        {
            return Err(failure());
        }
        let access = value["access_token"]
            .as_str()
            .filter(|s| token(s))
            .ok_or_else(failure)?
            .to_owned();
        let account_id = account(&access)?;
        if current.is_some_and(|s| s.account_id != account_id) {
            return Err(failure());
        }
        let refresh = value
            .get("refresh_token")
            .and_then(Value::as_str)
            .or_else(|| current.map(|s| s.refresh_token.as_str()))
            .filter(|s| token(s))
            .ok_or_else(failure)?
            .to_owned();
        let expires = value["expires_in"]
            .as_u64()
            .filter(|n| *n > 0 && *n <= 31_536_000)
            .ok_or_else(failure)?;
        Ok(Session {
            access_token: access,
            refresh_token: refresh,
            account_id,
            subject: current.map(|s| s.subject.clone()).unwrap_or_default(),
            expires_at: now() + expires,
            requires_reconnect: false,
        })
    }
    pub async fn credentials(self: &Arc<Self>, cancel: CancellationToken) -> Result<Session> {
        check_cancel(&cancel)?;
        let this = self.clone();
        // An owned refresh completes its persistence even when inference is cancelled.
        let task = self.tasks.spawn(async move {
            let _gate = this.gate.lock().await;
            let current = {
                let state = this.state.lock().unwrap();
                if state.blocked {
                    return Err(failure());
                }
                state
                    .session
                    .clone()
                    .filter(|s| !s.requires_reconnect)
                    .ok_or_else(failure)?
            };
            if current.expires_at > now() + 60 {
                return Ok(current);
            }
            if this.environment {
                return Err(Error::Invalid(
                    "Environment OpenAI credentials expired. Replace them externally and restart.",
                ));
            }
            let mut pending = current.clone();
            pending.requires_reconnect = true;
            // Persist the consumed-token marker BEFORE sending any refresh bytes.
            this.save(Some(pending)).await?;
            let response = this
                .exchange(form(&[
                    ("grant_type", "refresh_token"),
                    ("client_id", CLIENT_ID),
                    ("refresh_token", &current.refresh_token),
                ]))
                .await?;
            let updated = Self::replacement(&response, Some(&current))?;
            this.save(Some(updated.clone())).await?;
            Ok(updated)
        });
        tokio::select! {biased;_=cancel.cancelled()=>Err(Error::Cancelled),r=task=>r.map_err(|_|failure())?}
    }
    pub async fn connect(
        self: &Arc<Self>,
        challenge: oneshot::Sender<String>,
        cancel: CancellationToken,
    ) -> Result<()> {
        if self.environment {
            return Err(Error::Invalid(
                "Environment credentials are externally managed.",
            ));
        }
        let _gate = self.gate.lock().await;
        if self.state.lock().unwrap().blocked {
            return Err(failure());
        }
        let verifier = random()?;
        let state = random()?;
        let nonce = random()?;
        let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 1455))
            .await
            .map_err(|_| Error::Invalid("Cannot bind the local OAuth callback port 1455."))?;
        let mut url = reqwest::Url::parse("https://auth.openai.com/oauth/authorize").unwrap();
        url.query_pairs_mut().extend_pairs([
            ("client_id", CLIENT_ID),
            ("redirect_uri", REDIRECT),
            ("response_type", "code"),
            ("scope", "openid profile email offline_access"),
            ("state", &state),
            ("nonce", &nonce),
            (
                "code_challenge",
                &B64.encode(Sha256::digest(verifier.as_bytes())),
            ),
            ("code_challenge_method", "S256"),
            ("id_token_add_organizations", "true"),
            ("codex_cli_simplified_flow", "true"),
            ("originator", "exec_agent_rust"),
        ]);
        challenge
            .send(url.to_string())
            .map_err(|_| Error::Cancelled)?;
        let receive = async {
            // Only one valid callback is accepted. Invalid requests never consume the exchange.
            for _ in 0..32 {
                let (mut stream, peer) = listener.accept().await?;
                if !peer.ip().is_loopback() {
                    continue;
                }
                let read = async {
                    let mut bytes = Vec::new();
                    let mut byte = [0];
                    while bytes.len() < 8192 {
                        if stream.read(&mut byte).await? == 0 {
                            break;
                        }
                        bytes.push(byte[0]);
                        if bytes.ends_with(b"\r\n\r\n") {
                            break;
                        }
                    }
                    Ok::<_, Error>(bytes)
                };
                let bytes = tokio::time::timeout(Duration::from_secs(3), read)
                    .await
                    .map_err(|_| failure())??;
                let code = callback(&bytes, &state);
                let response = if code.is_ok() {
                    "HTTP/1.1 200 OK\r\nContent-Length: 38\r\nConnection: close\r\nContent-Type: text/plain\r\n\r\nSign-in received. Return to Exec now.\n"
                } else {
                    "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                };
                let _ = tokio::time::timeout(
                    Duration::from_secs(2),
                    stream.write_all(response.as_bytes()),
                )
                .await;
                if let Ok(code) = code {
                    return Ok(code);
                }
            }
            Err(failure())
        };
        let code = tokio::select! {biased;_=cancel.cancelled()=>return Err(Error::Cancelled),r=tokio::time::timeout(Duration::from_secs(300),receive)=>r.map_err(|_|failure())??};
        check_cancel(&cancel)?;
        // Once exchange begins it must settle, even if cancellation races with rotation.
        let value = self
            .exchange(form(&[
                ("grant_type", "authorization_code"),
                ("client_id", CLIENT_ID),
                ("redirect_uri", REDIRECT),
                ("code", &code),
                ("code_verifier", &verifier),
            ]))
            .await?;
        let id = value["id_token"].as_str().ok_or_else(failure)?;
        let keys = transport::json(
            self.transport.as_ref(),
            Request {
                session_id: None,
                endpoint: Endpoint::Keys,
                access: None,
                account: None,
                body: None,
            },
            128 * 1024,
            CancellationToken::new(),
        )
        .await?;
        let (subject, identity_account) = verify_identity(id, &nonce, &keys, now())?;
        let mut session = Self::replacement(&value, None)?;
        session.subject = subject;
        if identity_account.is_some_and(|a| a != session.account_id) {
            return Err(failure());
        }
        if self
            .state
            .lock()
            .unwrap()
            .session
            .as_ref()
            .is_some_and(|old| {
                old.subject != session.subject || old.account_id != session.account_id
            })
        {
            return Err(Error::Invalid(
                "Disconnect before selecting another OpenAI account.",
            ));
        }
        check_cancel(&cancel)?;
        self.save(Some(session)).await
    }
    pub async fn disconnect(self: &Arc<Self>) -> Result<()> {
        if self.environment {
            return Err(Error::Invalid(
                "Environment credentials are externally managed.",
            ));
        }
        let _gate = self.gate.lock().await;
        let current = self.state.lock().unwrap().session.clone();
        let revoked = if let Some(current) = current {
            let request = Request {
                session_id: None,
                endpoint: Endpoint::Revoke,
                access: None,
                account: None,
                body: Some(form(&[
                    ("token", &current.refresh_token),
                    ("token_type_hint", "refresh_token"),
                    ("client_id", CLIENT_ID),
                ])),
            };
            tokio::time::timeout(
                Duration::from_secs(30),
                self.transport.send(request, CancellationToken::new()),
            )
            .await
            .ok()
            .and_then(Result::ok)
            .is_some_and(|r| transport::status(r.status).is_ok())
        } else {
            true
        };
        self.save(None).await?;
        if !revoked {
            return Err(Error::Invalid(
                "Disconnected locally; remote revocation was not confirmed. Review ChatGPT sessions.",
            ));
        }
        Ok(())
    }
    pub async fn settle(&self) {
        self.tasks.close();
        self.tasks.wait().await;
    }
}
fn callback(bytes: &[u8], state: &str) -> Result<String> {
    let text = std::str::from_utf8(bytes).map_err(|_| failure())?;
    if !text.ends_with("\r\n\r\n") {
        return Err(failure());
    }
    let mut lines = text.split("\r\n");
    let first = lines.next().ok_or_else(failure)?;
    let parts: Vec<_> = first.split(' ').collect();
    if parts.len() != 3
        || parts[0] != "GET"
        || parts[2] != "HTTP/1.1"
        || !parts[1].starts_with("/auth/callback?")
    {
        return Err(failure());
    }
    let hosts: Vec<_> = lines
        .filter_map(|l| l.split_once(':'))
        .filter(|(k, _)| k.eq_ignore_ascii_case("host"))
        .map(|(_, v)| v.trim())
        .collect();
    if hosts.len() != 1 || !["localhost:1455", "127.0.0.1:1455"].contains(&hosts[0]) {
        return Err(failure());
    }
    let url = reqwest::Url::parse(&format!("http://localhost:1455{}", parts[1]))
        .map_err(|_| failure())?;
    let mut fields = std::collections::HashMap::new();
    for (key, value) in url.query_pairs() {
        if fields
            .insert(key.into_owned(), value.into_owned())
            .is_some()
        {
            return Err(failure());
        }
    }
    if fields.get("state").is_none_or(|s| s != state) || fields.contains_key("error") {
        return Err(failure());
    }
    fields
        .remove("code")
        .filter(|s| token(s) && s.len() <= 4096)
        .ok_or_else(failure)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn callback_requires_exact_state_host_and_unique_fields() {
        let request =
            |q: &str| format!("GET /auth/callback?{q} HTTP/1.1\r\nHost: localhost:1455\r\n\r\n");
        assert_eq!(
            callback(request("state=s&code=c").as_bytes(), "s").unwrap(),
            "c"
        );
        assert!(callback(request("state=x&code=c").as_bytes(), "s").is_err());
        assert!(callback(request("state=s&state=s&code=c").as_bytes(), "s").is_err());
        assert!(
            callback(
                request("state=s&code=c")
                    .replace("Host: localhost:1455", "Host: evil.test")
                    .as_bytes(),
                "s"
            )
            .is_err()
        );
    }
    #[test]
    fn identity_rejects_unsigned_and_unknown_keys() {
        let jwt = format!(
            "{}.{}.x",
            B64.encode(br#"{"alg":"none","kid":"k"}"#),
            B64.encode(br#"{"sub":"s"}"#)
        );
        assert!(verify_identity(&jwt, "n", &serde_json::json!({"keys":[]}), 1).is_err());
    }
}
