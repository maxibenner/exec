//! HTTP boundary only: one administrator credential and an independent native capability.
//! No provider tokens, user database, sessions, or runtime authorization logic live here.
use crate::{Error, Result};
use axum::http::HeaderMap;
use ring::hmac;

pub struct HttpAccess {
    api: Option<Token>,
    native: Option<Token>,
}
struct Token(hmac::Tag);
impl Token {
    fn new(secret: &str) -> Result<Self> {
        if secret.len() != 64 || !secret.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(Error::Invalid(
                "HTTP secrets must be 64 hexadecimal characters (32 random bytes).",
            ));
        }
        Ok(Self(hmac::sign(
            &hmac::Key::new(hmac::HMAC_SHA256, secret.as_bytes()),
            b"exec-agent-http-v1",
        )))
    }
    fn matches(&self, candidate: &str) -> bool {
        // ring performs constant-time tag verification. Neither credential is logged/stored.
        candidate.len() == 64
            && hmac::verify(
                &hmac::Key::new(hmac::HMAC_SHA256, candidate.as_bytes()),
                b"exec-agent-http-v1",
                self.0.as_ref(),
            )
            .is_ok()
    }
}
impl HttpAccess {
    pub fn bearer(api: &str, native: Option<&str>) -> Result<Self> {
        let api = Token::new(api)?;
        if native.is_some_and(|value| api.matches(value)) {
            return Err(Error::Invalid(
                "API and native capability credentials must be different.",
            ));
        }
        Ok(Self {
            api: Some(api),
            native: native.map(Token::new).transpose()?,
        })
    }
    /// Deliberate opt-out only for an externally enforced access boundary.
    /// This never implicitly grants the native capability.
    pub fn externally_secured(native: Option<&str>) -> Result<Self> {
        Ok(Self {
            api: None,
            native: native.map(Token::new).transpose()?,
        })
    }
    pub(crate) fn authorize(
        &self,
        headers: &HeaderMap,
        native: bool,
    ) -> std::result::Result<(), (u16, &'static str)> {
        if let Some(token) = &self.api {
            let credential = single_header(headers, "authorization").and_then(|v| {
                let (scheme, value) = v.split_once(' ')?;
                scheme.eq_ignore_ascii_case("Bearer").then_some(value)
            });
            if !credential.is_some_and(|v| token.matches(v)) {
                return Err((401, "A valid API bearer token is required."));
            }
        }
        if native
            && !self.native.as_ref().is_some_and(|token| {
                single_header(headers, "x-exec-native-token").is_some_and(|v| token.matches(v))
            })
        {
            return Err((
                403,
                "A separately provisioned native capability is required.",
            ));
        }
        Ok(())
    }
}
fn single_header<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
    let mut values = headers.get_all(name).iter();
    let value = values.next()?.to_str().ok()?;
    values.next().is_none().then_some(value)
}
