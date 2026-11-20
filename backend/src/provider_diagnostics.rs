//! Allowlisted provider failure details. Never retain reqwest errors, URLs,
//! headers, response bodies, credentials or arbitrary server-supplied text.
use crate::{Error, ProviderFailure};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum ProviderDiagnostic {
    HttpStatus {
        status: u16,
    },
    Transport {
        phase: ProviderTransportPhase,
        cause: ProviderTransportKind,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderTransportPhase {
    Setup,
    Send,
    Body,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderTransportKind {
    Timeout,
    Connect,
    Request,
    Body,
    Decode,
    Other,
}

/// Inspect only reqwest's typed predicates; Display/Debug and source strings may
/// contain a URL, credentials or response content and must never be persisted.
pub(crate) fn transport_error(error: reqwest::Error, phase: ProviderTransportPhase) -> Error {
    let cause = if error.is_timeout() {
        ProviderTransportKind::Timeout
    } else if error.is_connect() {
        ProviderTransportKind::Connect
    } else if error.is_request() {
        ProviderTransportKind::Request
    } else if error.is_body() {
        ProviderTransportKind::Body
    } else if error.is_decode() {
        ProviderTransportKind::Decode
    } else {
        ProviderTransportKind::Other
    };
    Error::ProviderDetailed {
        // Preserve existing user-facing failure categories and no-retry behavior.
        reason: ProviderFailure::Transport,
        detail: ProviderDiagnostic::Transport { phase, cause },
    }
}

pub(crate) fn http_error(reason: ProviderFailure, status: u16) -> Error {
    Error::ProviderDetailed {
        reason,
        detail: ProviderDiagnostic::HttpStatus { status },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::DiagnosticFailure;
    use futures_util::StreamExt;
    use std::time::Duration;
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };

    fn assert_redacted(error: Error, phase: ProviderTransportPhase, cause: ProviderTransportKind) {
        assert_eq!(
            error,
            Error::ProviderDetailed {
                reason: ProviderFailure::Transport,
                detail: ProviderDiagnostic::Transport { phase, cause },
            }
        );
        let wire = serde_json::to_string(&DiagnosticFailure::from(&error)).unwrap();
        for private in ["private-key", "private-prompt", "127.0.0.1", "http:"] {
            assert!(!wire.contains(private));
            assert!(!format!("{error:?}").contains(private));
            assert!(!error.to_string().contains(private));
        }
    }

    #[tokio::test]
    async fn classifies_connection_failure_without_retaining_url() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        drop(listener);
        let error = reqwest::Client::builder()
            .no_proxy()
            .build()
            .unwrap()
            .get(format!("http://{address}/private-prompt?token=private-key"))
            .send()
            .await
            .unwrap_err();
        assert_redacted(
            transport_error(error, ProviderTransportPhase::Send),
            ProviderTransportPhase::Send,
            ProviderTransportKind::Connect,
        );
    }

    #[tokio::test]
    async fn distinguishes_header_timeout_from_truncated_body() {
        for truncate in [false, true] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let server = tokio::spawn(async move {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut bytes = [0; 4096];
                assert!(socket.read(&mut bytes).await.unwrap() > 0);
                if truncate {
                    socket
                        .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 999\r\n\r\nprivate-prompt")
                        .await
                        .unwrap();
                } else {
                    std::future::pending::<()>().await;
                }
            });
            let client = reqwest::Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(2))
                .build()
                .unwrap();
            let request = client
                .get(format!("http://{address}/?token=private-key"))
                .send()
                .await;
            if truncate {
                let mut body = request.unwrap().bytes_stream();
                let error = loop {
                    match body.next().await {
                        Some(Err(error)) => break error,
                        Some(Ok(_)) => continue,
                        None => panic!("truncated body must fail"),
                    }
                };
                let classified = transport_error(error, ProviderTransportPhase::Body);
                assert_redacted(
                    classified,
                    ProviderTransportPhase::Body,
                    ProviderTransportKind::Decode,
                );
            } else {
                assert_redacted(
                    transport_error(request.unwrap_err(), ProviderTransportPhase::Send),
                    ProviderTransportPhase::Send,
                    ProviderTransportKind::Timeout,
                );
            }
            server.abort();
        }
    }

    #[test]
    fn builder_errors_do_not_expose_invalid_credentials() {
        let error = reqwest::Client::new()
            .get("https://example.invalid/private-prompt")
            .header("Authorization", "Bearer private-key\n")
            .build()
            .unwrap_err();
        assert_redacted(
            transport_error(error, ProviderTransportPhase::Setup),
            ProviderTransportPhase::Setup,
            ProviderTransportKind::Other,
        );
    }
}
