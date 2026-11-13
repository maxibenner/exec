#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let address = std::env::var("EXEC_RELAY_BIND").unwrap_or_else(|_| "127.0.0.1:8787".into());
    let listener = tokio::net::TcpListener::bind(address).await?;
    println!("Exec relay listening on {}", listener.local_addr()?);
    axum::serve(listener, exec_relay::router())
        .with_graceful_shutdown(async {
            let mut terminate =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                    .expect("signal handler");
            tokio::select! { _ = tokio::signal::ctrl_c() => {}, _ = terminate.recv() => {} }
        })
        .await?;
    Ok(())
}
