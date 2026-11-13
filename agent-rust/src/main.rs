use exec_agent::{
    Error, Result,
    providers::credentials::configured_deepseek_provider,
    service::{DEFAULT_ADDRESS, HttpAccess, start_persistent_service},
};
use std::{path::PathBuf, sync::Arc};
use tokio::signal::unix::{SignalKind, signal};

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
fn unblock_shutdown_signals() -> Result<()> {
    // GUI launchers may pass a blocked signal mask across exec. Register the
    // handlers first, then unblock their signals on this executable's main thread.
    // SAFETY: set points to initialized storage; pthread_sigmask copies it.
    let result = unsafe {
        let mut set = std::mem::zeroed::<libc::sigset_t>();
        libc::sigemptyset(&mut set);
        libc::sigaddset(&mut set, libc::SIGINT);
        libc::sigaddset(&mut set, libc::SIGTERM);
        libc::pthread_sigmask(libc::SIG_UNBLOCK, &set, std::ptr::null_mut())
    };
    if result != 0 {
        return Err(std::io::Error::from_raw_os_error(result).into());
    }
    Ok(())
}

async fn run() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let mut profile = std::env::home_dir()
        .ok_or(Error::Invalid("Home directory is unavailable."))?
        .join(".exec-agent");
    let mut credentials = None;
    let mut tools = false;
    let mut insecure = false;
    let mut port = None;
    let mut host = None;
    let mut profile_set = false;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--profile" if !profile_set => {
                profile = PathBuf::from(
                    args.next()
                        .ok_or(Error::Invalid("--profile requires a path."))?,
                );
                profile_set = true;
            }
            "--credentials" if credentials.is_none() => {
                credentials = Some(PathBuf::from(
                    args.next()
                        .ok_or(Error::Invalid("--credentials requires a path."))?,
                ));
            }
            "--workspace-tools" if !tools => tools = true,
            "--insecure-no-auth" if !insecure => insecure = true,
            "--host" if host.is_none() => {
                host = Some(
                    args.next()
                        .ok_or(Error::Invalid("--host requires an IP address."))?,
                );
            }
            "--port" if port.is_none() => {
                port = Some(
                    args.next()
                        .ok_or(Error::Invalid("--port requires a port."))?,
                );
            }
            _ => {
                return Err(Error::Invalid(
                    "Invalid backend arguments. Only --profile, --credentials, --workspace-tools, --host, --port and --insecure-no-auth are supported; there is no CLI client.",
                ));
            }
        }
    }
    if !profile.is_absolute() {
        profile = std::env::current_dir()?.join(profile);
    }
    // Explicit flags override environment values; no discovery or fallback binding.
    let mut address: std::net::SocketAddr = DEFAULT_ADDRESS.parse().unwrap();
    if let Some(host) = setting(host, "EXEC_AGENT_HOST")? {
        let ip = host
            .parse::<std::net::IpAddr>()
            .map_err(|_| Error::Invalid("Host must be a numeric network IP address."))?;
        address.set_ip(ip);
    }
    if let Some(port) = setting(port, "EXEC_AGENT_PORT")? {
        let port = port
            .parse::<u16>()
            .ok()
            .filter(|p| *p > 0)
            .ok_or(Error::Invalid("Port must be from 1 to 65535."))?;
        address.set_port(port);
    }
    let token = setting(None, "EXEC_AGENT_TOKEN")?;
    let native_token = setting(None, "EXEC_AGENT_NATIVE_TOKEN")?;
    let access = match (insecure, token.as_deref()) {
        (false, Some(token)) => HttpAccess::bearer(token, native_token.as_deref())?,
        (true, None) => HttpAccess::externally_secured(native_token.as_deref())?,
        (true, Some(_)) => {
            return Err(Error::Invalid(
                "Do not combine EXEC_AGENT_TOKEN with --insecure-no-auth.",
            ));
        }
        (false, None) => {
            return Err(Error::Invalid(
                "Set EXEC_AGENT_TOKEN to 32 random bytes encoded as 64 hex characters, or explicitly use --insecure-no-auth behind an enforced external access boundary.",
            ));
        }
    };
    if !address.ip().to_canonical().is_loopback() {
        eprintln!(
            "Network HTTP binding enabled. Require TLS termination or an encrypted tunnel and restrict direct access to this port."
        );
    }
    let mut interrupt = signal(SignalKind::interrupt())?;
    let mut terminate = signal(SignalKind::terminate())?;
    unblock_shutdown_signals()?;
    let provider = Arc::new(configured_deepseek_provider(&profile, credentials.clone()).await?);
    let openai = Arc::new(
        exec_agent::providers::openai::OpenAIProvider::configured(
            credentials.unwrap_or_else(|| profile.join("credentials.json")),
            match std::env::var("OPENAI_SESSION_JSON") {
                Ok(value) => Some(value),
                Err(std::env::VarError::NotPresent) => None,
                Err(_) => return Err(Error::Invalid("Invalid OpenAI session environment.")),
            },
        )
        .await?,
    );
    let provider = Arc::new(
        exec_agent::providers::ProviderRegistry::new(
            "deepseek",
            vec![("deepseek".into(), provider), ("openai".into(), openai)],
        )?
        .with_cache(profile.join("metadata.json"))
        .await?,
    );

    let service = start_persistent_service(&profile, provider, tools, address, access).await
        .map_err(|_| Error::Invalid("Backend startup failed. Check port availability, profile permissions and store ownership; no stale state was removed."))?;
    // Readiness only: clients already know the configured endpoint. Never discover another server.
    println!("ready");
    tokio::select! { _ = interrupt.recv() => {}, _ = terminate.recv() => {} }
    service.close().await
}

fn setting(explicit: Option<String>, name: &str) -> Result<Option<String>> {
    if explicit.is_some() {
        return Ok(explicit);
    }
    match std::env::var(name) {
        Ok(value) => Ok(Some(value)),
        Err(std::env::VarError::NotPresent) => Ok(None),
        Err(_) => Err(Error::Invalid("Invalid HTTP configuration environment.")),
    }
}
