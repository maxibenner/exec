mod support;
use async_trait::async_trait;
use exec_agent::{Error, content_fetch::*, core::*, tools::create_fetch_tool_with};
use serde_json::json;
use std::{
    collections::VecDeque,
    net::SocketAddr,
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
};
use tokio_util::sync::CancellationToken;

struct Dns;
#[async_trait]
impl Resolver for Dns {
    async fn resolve(&self, host: &str) -> exec_agent::Result<Vec<SocketAddr>> {
        Ok(if host == "private.example.com" {
            vec!["127.0.0.1:443".parse().unwrap()]
        } else {
            vec!["1.1.1.1:443".parse().unwrap()]
        })
    }
}
struct Pages {
    responses: Mutex<VecDeque<PageResponse>>,
    count: AtomicUsize,
}
#[async_trait]
impl PageTransport for Pages {
    async fn get(
        &self,
        url: &reqwest::Url,
        addresses: &[SocketAddr],
        _: CancellationToken,
    ) -> exec_agent::Result<PageResponse> {
        assert_eq!(url.scheme(), "https");
        assert_eq!(addresses, ["1.1.1.1:443".parse().unwrap()]);
        self.count.fetch_add(1, Ordering::SeqCst);
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .ok_or(Error::Internal)
    }
}
fn page(status: u16, mime: &str, location: Option<&str>, body: Vec<u8>) -> PageResponse {
    PageResponse {
        status,
        content_type: mime.into(),
        location: location.map(str::to_owned),
        body: Box::pin(futures_util::stream::once(async move {
            Ok(bytes::Bytes::from(body))
        })),
    }
}
fn fetcher(pages: Vec<PageResponse>) -> (ContentFetcher, Arc<Pages>) {
    let pages = Arc::new(Pages {
        responses: Mutex::new(pages.into()),
        count: AtomicUsize::new(0),
    });
    (ContentFetcher::new(Arc::new(Dns), pages.clone()), pages)
}
#[test]
fn urls_and_addresses_reject_private_credentials_nonstandard_ports_and_special_ranges() {
    for url in [
        "http://example.com",
        "https://user:pass@example.com",
        "https://example.com:8443",
        "https://localhost",
        "https://127.0.0.1",
        "https://2130706433",
        "https://[::1]",
        "https://service.internal",
        "https://x.home.arpa",
        "https://example.com/\nsecret",
    ] {
        assert!(public_url(url).is_err(), "{url}");
    }
    for ip in [
        "0.0.0.0",
        "10.0.0.1",
        "100.64.0.1",
        "127.0.0.1",
        "169.254.169.254",
        "172.16.0.1",
        "192.168.0.1",
        "192.0.2.1",
        "198.18.0.1",
        "203.0.113.1",
        "224.0.0.1",
        "255.255.255.255",
        "::1",
        "fc00::1",
        "fe80::1",
        "::ffff:8.8.8.8",
        "2001:db8::1",
        "2002:7f00:1::1",
        "3fff::1",
    ] {
        assert!(!public_address(ip.parse().unwrap()), "{ip}");
    }
    for ip in ["1.1.1.1", "8.8.8.8", "2606:4700:4700::1111"] {
        assert!(public_address(ip.parse().unwrap()), "{ip}");
    }
}
#[test]
fn html_extraction_uses_parser_and_skips_executable_or_noncontent_nodes() {
    let (text, truncated) = extract_text(b"<html><head><title>Hidden title</title><script>secret</script></head><body><h1>Hello &amp; world</h1><script>private</script><style>bad</style><p>Visible</p></body></html>", "text/html").unwrap();
    assert_eq!(text, "Hello & world Visible");
    assert!(!truncated);
    let source = "🙂".repeat(10000);
    let (text, truncated) = extract_text(source.as_bytes(), "text/plain").unwrap();
    assert_eq!(text.len(), 24000);
    assert!(truncated);
    assert!(text.ends_with('🙂'));
    assert!(extract_text(&[0xff], "text/plain").is_err());
}
#[tokio::test]
async fn redirects_upgrade_https_and_revalidate_dns_before_each_request() {
    let (fetcher, pages) = fetcher(vec![
        page(302, "text/plain", Some("http://example.com/page"), vec![]),
        page(
            200,
            "text/html; charset=utf-8",
            None,
            b"<p>Public text</p>".to_vec(),
        ),
    ]);
    let result = fetcher
        .fetch("https://example.com", CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(result.url, "https://example.com/page");
    assert_eq!(result.text, "Public text");
    assert_eq!(pages.count.load(Ordering::SeqCst), 2);
    let (fetcher, pages) = self::fetcher(vec![page(
        302,
        "text/plain",
        Some("https://private.example.com"),
        vec![],
    )]);
    assert!(
        fetcher
            .fetch("https://example.com", CancellationToken::new())
            .await
            .is_err()
    );
    assert_eq!(pages.count.load(Ordering::SeqCst), 1);
}
#[tokio::test]
async fn oversized_binary_failed_and_redirect_loop_responses_never_retry() {
    for response in [
        page(200, "text/plain", None, vec![b'x'; 1024 * 1024 + 1]),
        page(200, "application/pdf", None, vec![]),
        page(500, "text/plain", None, b"private raw diagnostics".to_vec()),
    ] {
        let (fetcher, pages) = fetcher(vec![response]);
        let error = fetcher
            .fetch("https://example.com", CancellationToken::new())
            .await
            .unwrap_err();
        assert!(!error.to_string().contains("private raw diagnostics"));
        assert_eq!(pages.count.load(Ordering::SeqCst), 1);
    }
    let (fetcher, pages) = fetcher(
        (0..4)
            .map(|_| page(302, "text/plain", Some("/again"), vec![]))
            .collect(),
    );
    assert!(
        fetcher
            .fetch("https://example.com", CancellationToken::new())
            .await
            .is_err()
    );
    assert_eq!(pages.count.load(Ordering::SeqCst), 4);
}
#[tokio::test]
async fn cancellation_and_runner_fetch_use_fake_transport_only() {
    let pending = PageResponse {
        status: 200,
        content_type: "text/plain".into(),
        location: None,
        body: Box::pin(futures_util::stream::pending()),
    };
    let (fetcher, pages) = fetcher(vec![pending]);
    let cancel = CancellationToken::new();
    let stopped = cancel.clone();
    let task = tokio::spawn(async move { fetcher.fetch("https://example.com", stopped).await });
    tokio::time::timeout(std::time::Duration::from_secs(3), async {
        while pages.count.load(Ordering::SeqCst) == 0 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    cancel.cancel();
    assert_eq!(task.await.unwrap().unwrap_err(), Error::Cancelled);
    let (fetcher, _) = self::fetcher(vec![page(200, "text/plain", None, b"Evidence".to_vec())]);
    let call = ProviderEvent::ToolCall(ToolCall {
        id: "fetch-1".into(),
        name: "fetch_content".into(),
        arguments: json!({"url":"https://example.com/page"})
            .as_object()
            .unwrap()
            .clone(),
    });
    let p = support::FakeProvider::new(vec![
        support::response(vec![call, ProviderEvent::Done]),
        support::answer(),
    ]);
    let c = support::conversation(p, vec![create_fetch_tool_with(fetcher)]);
    assert_eq!(
        support::complete(c.submit("Read public page".into()).unwrap())
            .await
            .state,
        OperationState::Completed
    );
    assert!(
        c.snapshot()
            .messages
            .iter()
            .any(|m| m.text().contains("Evidence"))
    );
    assert!(c.snapshot().messages.iter().any(|m|matches!(m,Message::Tool{details:Some(ToolDetails::Page{content}),..} if content.text=="Evidence")));
}
