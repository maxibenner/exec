//! Deployment configuration checks only; never contact a Docker daemon/registry.
use exec_relay::HostAdmission;
use serde_json::Value;
use std::{io::ErrorKind, net::SocketAddr, path::Path, process::Command};

const COMPOSE: &str = include_str!("../../compose.yaml");
const ROUTE: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

#[test]
fn compose_allows_private_bootstrap_but_requires_routes_for_relay_startup() {
    // Keep bootstrap renderable without admitting arbitrary hosts. This also
    // runs on machines without Docker; the rendered check below is stronger.
    assert!(COMPOSE.contains("EXEC_RELAY_BIND: 0.0.0.0:8787"));
    assert!(COMPOSE.contains("EXEC_RELAY_ALLOWED_ROUTES: ${EXEC_RELAY_ALLOWED_ROUTES:-}"));
    assert!(!COMPOSE.contains("EXEC_RELAY_LOCAL_DEVELOPMENT"));
    let bind = "0.0.0.0".parse().unwrap();
    for routes in [None, Some("")] {
        assert!(HostAdmission::from_config(bind, routes, false).is_err());
    }
    assert!(HostAdmission::from_config(bind, Some(ROUTE), false).is_ok());
}

#[test]
fn rendered_compose_forwards_only_public_relay_configuration() {
    let compose_path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../compose.yaml");
    for routes in [None, Some(""), Some(ROUTE)] {
        let mut command = Command::new("docker");
        command
            .env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            // Docker Desktop installs the Compose plugin under the user home.
            // `config` only renders locally; it never requests credentials.
            .env("HOME", std::env::var_os("HOME").unwrap_or_default())
            .env("EXEC_RELAY_DOMAIN", "relay.example.invalid")
            .env("EXEC_RELAY_LOCAL_DEVELOPMENT", "1")
            .args([
                "compose",
                "--env-file",
                "/dev/null",
                "--project-name",
                "exec-remote-admission-test",
                "--file",
            ])
            .arg(&compose_path)
            .args(["config", "--format", "json"]);
        if let Some(routes) = routes {
            command.env("EXEC_RELAY_ALLOWED_ROUTES", routes);
        }
        let output = match command.output() {
            Ok(output) => output,
            Err(error) if error.kind() == ErrorKind::NotFound => {
                eprintln!(
                    "Docker CLI unavailable; static Compose/startup policy check still runs."
                );
                return;
            }
            Err(error) => panic!("cannot render Compose configuration: {error}"),
        };
        assert!(
            output.status.success(),
            "Compose render failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let config: Value = serde_json::from_slice(&output.stdout).unwrap();
        let environment = config["services"]["relay"]["environment"]
            .as_object()
            .unwrap();
        assert_eq!(
            environment.len(),
            2,
            "do not forward secrets or development admission"
        );
        let bind: SocketAddr = environment["EXEC_RELAY_BIND"]
            .as_str()
            .unwrap()
            .parse()
            .unwrap();
        assert_eq!(bind, "0.0.0.0:8787".parse().unwrap());
        let forwarded = environment["EXEC_RELAY_ALLOWED_ROUTES"].as_str().unwrap();
        assert_eq!(forwarded, routes.unwrap_or_default());
        // This is the actual startup validator, applied to the rendered values.
        assert_eq!(
            HostAdmission::from_config(bind.ip(), Some(forwarded), false).is_ok(),
            routes == Some(ROUTE)
        );
        assert!(config["services"]["agent"]["ports"].is_null());
        assert!(config["services"]["relay"]["ports"].is_null());
        assert_eq!(config["networks"]["relay_private"]["internal"], true);
    }
}
