mod http;
mod oauth;
mod terminal;

use http::{Api, INVALID_RESPONSE};
use reqwest::{Method, Url};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::io::Write;
use terminal::Signals;

type Result<T> = std::result::Result<T, &'static str>;
const ARGUMENTS: &str =
    "Invalid arguments. Run exec-agent-admin --help. Credentials are never accepted as arguments.";
const HELP: &str = "exec-agent-admin — local Exec administration

Usage:
  exec-agent-admin help | --help
  exec-agent-admin init-token
  exec-agent-admin health
  exec-agent-admin providers list | status
  exec-agent-admin providers connect deepseek [--key-stdin]
  exec-agent-admin providers connect openai --device-code
  exec-agent-admin providers disconnect ID
  exec-agent-admin providers login-status
  exec-agent-admin providers cancel-login ATTEMPT_ID
  exec-agent-admin remote status
  exec-agent-admin remote configure --relay wss://HOST[:PORT] [--disable] [--local-development]
  exec-agent-admin remote invite
  exec-agent-admin remote revoke DEVICE_ID

The HTTP endpoint is always 127.0.0.1 (EXEC_AGENT_PORT, default 8765).
Authentication uses EXEC_AGENT_TOKEN or EXEC_AGENT_TOKEN_FILE, never both (even empty).
EXEC_AGENT_DEFAULT_TOKEN_FILE is used only when neither explicit source is set.
init-token uses the shared server token initializer and prints nothing.
Provider IDs: deepseek, openai. No secrets are accepted as command arguments.
DeepSeek prompts without echo; --key-stdin explicitly reads a pipe/file (8192 bytes, 60s).
OpenAI device login and invitation JSON require interactive terminal stdin/stdout.
No browser is launched. Ctrl-C/SIGTERM/SIGHUP requests cancellation of that OpenAI attempt once.
Cancellation reports an observed terminal state or an unknown outcome, not just acceptance.
After an unknown outcome, inspect login-status and providers status before another login.
Cancel only the exact observed attempt ID; never blindly replay login or cancellation.
Requests have bounded responses/timeouts, with no proxies, redirects or retries.
";

#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
enum ProviderId {
    DeepSeek,
    OpenAi,
}
impl ProviderId {
    fn parse(value: &str) -> Result<Self> {
        match value {
            "deepseek" => Ok(Self::DeepSeek),
            "openai" => Ok(Self::OpenAi),
            _ => Err("Provider ID must be deepseek or openai."),
        }
    }
    fn id(self) -> &'static str {
        match self {
            Self::DeepSeek => "deepseek",
            Self::OpenAi => "openai",
        }
    }
    fn name(self) -> &'static str {
        match self {
            Self::DeepSeek => "DeepSeek",
            Self::OpenAi => "OpenAI (ChatGPT subscription)",
        }
    }
}

enum Command {
    Help,
    InitToken,
    Health,
    Providers,
    DeepSeek {
        from_stdin: bool,
    },
    OpenAi,
    Disconnect(ProviderId),
    LoginStatus,
    CancelLogin(String),
    RemoteStatus,
    Configure {
        relay: String,
        enabled: bool,
        local: bool,
    },
    Invite,
    Revoke(String),
}

fn parse(args: &[&str]) -> Result<Command> {
    match args {
        [] | ["help"] | ["--help"] | ["providers", "--help"] | ["remote", "--help"] => {
            Ok(Command::Help)
        }
        ["init-token"] => Ok(Command::InitToken),
        ["health"] => Ok(Command::Health),
        ["providers", "list" | "status"] => Ok(Command::Providers),
        ["providers", "connect", "deepseek"] => Ok(Command::DeepSeek { from_stdin: false }),
        ["providers", "connect", "deepseek", "--key-stdin"] => {
            Ok(Command::DeepSeek { from_stdin: true })
        }
        ["providers", "connect", "openai", "--device-code"] => Ok(Command::OpenAi),
        ["providers", "connect", "openai"] => {
            Err("OpenAI login requires --device-code and an interactive terminal.")
        }
        ["providers", "disconnect", id] => Ok(Command::Disconnect(ProviderId::parse(id)?)),
        ["providers", "login-status"] => Ok(Command::LoginStatus),
        ["providers", "cancel-login", id] if exec_agent::core::valid_id(id) => {
            Ok(Command::CancelLogin((*id).to_owned()))
        }
        ["remote", "status"] => Ok(Command::RemoteStatus),
        ["remote", "configure", options @ ..] => parse_configure(options),
        ["remote", "invite"] => Ok(Command::Invite),
        ["remote", "revoke", id] if exec_agent::core::valid_id(id) => {
            Ok(Command::Revoke((*id).to_owned()))
        }
        _ => Err(ARGUMENTS),
    }
}

fn parse_configure(options: &[&str]) -> Result<Command> {
    let mut relay = None;
    let mut disable = false;
    let mut local = false;
    let mut args = options.iter();
    while let Some(option) = args.next() {
        match *option {
            "--relay" if relay.is_none() => relay = Some(*args.next().ok_or(ARGUMENTS)?),
            "--disable" if !disable => disable = true,
            "--local-development" if !local => local = true,
            _ => return Err(ARGUMENTS),
        }
    }
    let relay = relay.ok_or("remote configure requires --relay.")?;
    validate_relay(relay, local)?;
    Ok(Command::Configure {
        relay: relay.to_owned(),
        enabled: !disable,
        local,
    })
}

fn validate_relay(value: &str, local: bool) -> Result<()> {
    const INVALID: &str = "Use a wss:// relay with only a host and optional port; private-network ws:// requires --local-development.";
    if value.len() > 2048 || value.chars().any(char::is_control) {
        return Err(INVALID);
    }
    let url = Url::parse(value).map_err(|_| INVALID)?;
    let private = url.host_str().is_some_and(|host| {
        host == "localhost"
            || host
                .trim_start_matches('[')
                .trim_end_matches(']')
                .parse::<std::net::IpAddr>()
                .is_ok_and(|ip| match ip {
                    std::net::IpAddr::V4(ip) => ip.is_loopback() || ip.is_private(),
                    std::net::IpAddr::V6(ip) => ip.is_loopback() || ip.is_unique_local(),
                })
    });
    if url.host().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.path() != "/"
        || !(url.scheme() == "wss" || (local && private && url.scheme() == "ws"))
    {
        return Err(INVALID);
    }
    Ok(())
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Health {
    version: u32,
    tools_enabled: bool,
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
enum Source {
    Environment,
    Json,
}
#[derive(Deserialize, Serialize)]
struct ProviderStatus {
    id: ProviderId,
    #[serde(skip_deserializing)]
    name: String,
    connected: bool,
    source: Source,
    manageable: bool,
    blocked: bool,
}
fn providers(mut rows: Vec<ProviderStatus>) -> Result<()> {
    for row in &mut rows {
        // Names are provider labels, never account display names or server-supplied diagnostics.
        row.name = row.id.name().to_owned();
    }
    output(&rows)
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
enum RemoteConnection {
    Disconnected,
    Connecting,
    Connected,
    RelayNotFound,
}
#[derive(Deserialize, Serialize)]
struct Device {
    id: String,
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct RemoteStatus {
    enabled: bool,
    relay: String,
    local_development: bool,
    connected: bool,
    connection_status: RemoteConnection,
    invitation_active: bool,
    devices: Vec<Device>,
}
fn remote_status(status: RemoteStatus) -> Result<()> {
    if !status.relay.is_empty() {
        validate_relay(&status.relay, status.local_development).map_err(|_| INVALID_RESPONSE)?;
    }
    if status
        .devices
        .iter()
        .any(|d| !exec_agent::core::valid_id(&d.id))
    {
        return Err(INVALID_RESPONSE);
    }
    // Device names may contain personal information; project only the revocable pairing IDs.
    output(&status)
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Invitation {
    version: u32,
    relay: String,
    route: String,
    host_key: String,
    secret: String,
    expires: u64,
    local_development: bool,
}
fn invitation(value: Invitation) -> Result<()> {
    terminal::require_interactive()?;
    validate_relay(&value.relay, value.local_development).map_err(|_| INVALID_RESPONSE)?;
    if [&value.route, &value.host_key, &value.secret]
        .iter()
        .any(|s| s.is_empty() || s.len() > 512 || !s.bytes().all(|b| (0x21..=0x7e).contains(&b)))
    {
        return Err(INVALID_RESPONSE);
    }
    output(&value)
}

fn output(value: &impl Serialize) -> Result<()> {
    const FAILED: &str = "Cannot write command output; the operation may have taken effect. Inspect service state before continuing.";
    let mut stdout = std::io::stdout().lock();
    serde_json::to_writer_pretty(&mut stdout, value).map_err(|_| FAILED)?;
    writeln!(stdout).map_err(|_| FAILED)
}

pub(super) async fn run() -> Result<()> {
    let args = std::env::args_os()
        .skip(1)
        .map(|s| s.into_string().map_err(|_| ARGUMENTS))
        .collect::<Result<Vec<_>>>()?;
    let command = parse(&args.iter().map(String::as_str).collect::<Vec<_>>())?;
    match command {
        Command::Help => return std::io::stdout().write_all(HELP.as_bytes()).map_err(|_| "Cannot write help."),
        Command::InitToken => return exec_agent::server_config::initialize_api_token()
            .map_err(|_| "Cannot initialize the administrator token. Check EXEC_AGENT_TOKEN / EXEC_AGENT_TOKEN_FILE and file permissions."),
        Command::OpenAi | Command::Invite => terminal::require_interactive()?,
        Command::DeepSeek { from_stdin } => terminal::check_key_input(from_stdin)?,
        _ => {},
    }
    let api = Api::new()?;
    match command {
        Command::Health => output(
            &api.request::<Health>(Method::GET, "/v1/health", None)
                .await?,
        ),
        Command::Providers => providers(api.request(Method::GET, "/v1/providers", None).await?),
        Command::DeepSeek { from_stdin } => {
            let signals = Signals::new()?;
            let key = terminal::read_key(from_stdin, signals.cancel.clone()).await?;
            if signals.cancel.is_cancelled() {
                return Err(terminal::INTERRUPTED);
            }
            providers(
                api.request(
                    Method::PUT,
                    "/v1/providers/deepseek",
                    Some(json!({"apiKey":key})),
                )
                .await?,
            )
        }
        Command::OpenAi => oauth::connect(&api, Signals::new()?).await,
        Command::Disconnect(provider) => providers(
            api.request(
                Method::DELETE,
                &format!("/v1/providers/{}", provider.id()),
                None,
            )
            .await?,
        ),
        Command::LoginStatus => oauth::status(&api).await,
        Command::CancelLogin(id) => oauth::cancel(&api, &id).await,
        Command::RemoteStatus => remote_status(api.request(Method::GET, "/v1/remote", None).await?),
        Command::Configure {
            relay,
            enabled,
            local,
        } => remote_status(
            api.request(
                Method::PUT,
                "/v1/remote",
                Some(json!({"relay":relay,"enabled":enabled,"localDevelopment":local})),
            )
            .await?,
        ),
        Command::Invite => invitation(
            api.request(Method::POST, "/v1/remote/invitations", Some(json!({})))
                .await?,
        ),
        Command::Revoke(id) => remote_status(
            api.request(Method::DELETE, &format!("/v1/remote/devices/{id}"), None)
                .await?,
        ),
        Command::Help | Command::InitToken => unreachable!(),
    }
}
