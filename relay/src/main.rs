#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let address = std::env::var("EXEC_RELAY_BIND").unwrap_or_else(|_| "127.0.0.1:8787".into());
    let listener = tokio::net::TcpListener::bind(address).await?;
    let routes = match std::env::var("EXEC_RELAY_ALLOWED_ROUTES") {
        Ok(routes) => Some(routes),
        Err(std::env::VarError::NotPresent) => None,
        Err(_) => return Err("EXEC_RELAY_ALLOWED_ROUTES must be UTF-8.".into()),
    };
    let local_development = match std::env::var("EXEC_RELAY_LOCAL_DEVELOPMENT").as_deref() {
        Ok("1") => true,
        Err(std::env::VarError::NotPresent) => false,
        _ => return Err("EXEC_RELAY_LOCAL_DEVELOPMENT must be unset or 1.".into()),
    };
    let admission = exec_relay::HostAdmission::from_config(
        listener.local_addr()?.ip(),
        routes.as_deref(),
        local_development,
    )?;
    println!("Exec relay listening on {}", listener.local_addr()?);
    axum::serve(listener, exec_relay::router(admission))
        .with_graceful_shutdown(async {
            let mut terminate =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                    .expect("signal handler");
            tokio::select! { _ = tokio::signal::ctrl_c() => {}, _ = terminate.recv() => {} }
        })
        .await?;
    Ok(())
}
