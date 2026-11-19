#[path = "../admin/mod.rs"]
mod admin;

#[tokio::main(flavor = "current_thread")]
async fn main() -> std::process::ExitCode {
    match admin::run().await {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(message) => {
            use std::io::Write;
            let _ = writeln!(std::io::stderr(), "exec-agent-admin: {message}");
            std::process::ExitCode::FAILURE
        }
    }
}
