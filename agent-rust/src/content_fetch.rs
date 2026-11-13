//! Direct public-page fetching, separate from model/provider transports and credentials.
use crate::{Error, Result, check_cancel, providers::response_stream::ByteStream};
use async_trait::async_trait;
use futures_util::StreamExt;
use reqwest::Url;
use serde::{Deserialize, Serialize};
use std::{
    net::{IpAddr, SocketAddr},
    sync::Arc,
    time::Duration,
};
use tokio_util::sync::CancellationToken;
const BODY_LIMIT: usize = 1024 * 1024;
const TEXT_LIMIT: usize = 24000;
fn failure() -> Error {
    Error::Tool(
        "Content fetch failed or the public page was unsupported. No retry was made.".into(),
    )
}

pub fn public_address(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => {
            let value = u32::from(ip);
            ![
                (0x00000000, 8),
                (0x0a000000, 8),
                (0x64400000, 10),
                (0x7f000000, 8),
                (0xa9fe0000, 16),
                (0xac100000, 12),
                (0xc0000000, 24),
                (0xc0000200, 24),
                (0xc0586300, 24),
                (0xc0a80000, 16),
                (0xc6120000, 15),
                (0xc6336400, 24),
                (0xcb007100, 24),
                (0xe0000000, 3),
            ]
            .iter()
            .any(|(network, bits)| value >> (32 - bits) == network >> (32 - bits))
        }
        IpAddr::V6(ip) => {
            let b = ip.octets();
            b[0] & 0xe0 == 0x20
                && !(b[0] == 0x20 && b[1] == 1 && (b[2] < 2 || (b[2] == 0x0d && b[3] == 0xb8)))
                && !(b[0] == 0x20 && b[1] == 2)
                && !(b[0] == 0x3f && b[1] == 0xff && b[2] & 0xf0 == 0)
        }
    }
}
pub fn public_url(text: &str) -> Result<Url> {
    if text.is_empty()
        || text.len() > 2048
        || text.chars().any(|c| c.is_whitespace() || c.is_control())
    {
        return Err(failure());
    }
    let mut url = Url::parse(text).map_err(|_| failure())?;
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port_or_known_default() != Some(443)
    {
        return Err(failure());
    }
    let host = url
        .host_str()
        .ok_or_else(failure)?
        .trim_matches(['[', ']'])
        .trim_end_matches('.')
        .to_lowercase();
    if !host.contains(['.', ':'])
        || [
            "localhost",
            "local",
            "internal",
            "home",
            "lan",
            "test",
            "invalid",
            "onion",
            "home.arpa",
        ]
        .iter()
        .any(|suffix| host == *suffix || host.ends_with(&format!(".{suffix}")))
    {
        return Err(failure());
    }
    if let Ok(ip) = host.parse::<IpAddr>()
        && !public_address(ip)
    {
        return Err(failure());
    }
    url.set_fragment(None);
    Ok(url)
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct FetchedContent {
    pub url: String,
    pub content_type: String,
    pub text: String,
    pub truncated: bool,
}
#[async_trait]
pub trait Resolver: Send + Sync {
    async fn resolve(&self, host: &str) -> Result<Vec<SocketAddr>>;
}
pub struct SystemResolver;
#[async_trait]
impl Resolver for SystemResolver {
    async fn resolve(&self, host: &str) -> Result<Vec<SocketAddr>> {
        tokio::net::lookup_host((host, 443))
            .await
            .map(|addresses| addresses.collect())
            .map_err(|_| failure())
    }
}
pub struct PageResponse {
    pub status: u16,
    pub content_type: String,
    pub location: Option<String>,
    pub body: ByteStream,
}
#[async_trait]
pub trait PageTransport: Send + Sync {
    async fn get(
        &self,
        url: &Url,
        addresses: &[SocketAddr],
        cancel: CancellationToken,
    ) -> Result<PageResponse>;
}
pub struct PublicPageTransport;
#[async_trait]
impl PageTransport for PublicPageTransport {
    async fn get(
        &self,
        url: &Url,
        addresses: &[SocketAddr],
        cancel: CancellationToken,
    ) -> Result<PageResponse> {
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .no_proxy()
            .pool_max_idle_per_host(0)
            .timeout(Duration::from_secs(20))
            .resolve_to_addrs(url.host_str().ok_or_else(failure)?, addresses)
            .build()
            .map_err(|_| failure())?;
        let response = tokio::select! { biased; _ = cancel.cancelled() => return Err(Error::Cancelled), result = client.get(url.clone()).header("Accept", "text/html, text/plain, text/markdown, application/json;q=0.8").header("User-Agent", "Exec/1.0").send() => result.map_err(|_| failure())? };
        if response
            .remote_addr()
            .is_none_or(|peer| !addresses.contains(&peer) || !public_address(peer.ip()))
        {
            return Err(failure());
        }
        if response
            .content_length()
            .is_some_and(|size| size > BODY_LIMIT as u64)
        {
            return Err(failure());
        }
        let header = |key| {
            response
                .headers()
                .get(key)
                .and_then(|v| v.to_str().ok())
                .map(str::to_owned)
        };
        Ok(PageResponse {
            status: response.status().as_u16(),
            content_type: header("content-type").unwrap_or_default(),
            location: header("location"),
            body: Box::pin(
                response
                    .bytes_stream()
                    .map(|chunk| chunk.map_err(|_| failure())),
            ),
        })
    }
}
#[derive(Clone)]
pub struct ContentFetcher {
    resolver: Arc<dyn Resolver>,
    transport: Arc<dyn PageTransport>,
}
impl Default for ContentFetcher {
    fn default() -> Self {
        Self::new(Arc::new(SystemResolver), Arc::new(PublicPageTransport))
    }
}
impl ContentFetcher {
    pub fn new(resolver: Arc<dyn Resolver>, transport: Arc<dyn PageTransport>) -> Self {
        Self {
            resolver,
            transport,
        }
    }
    pub async fn fetch(&self, url: &str, cancel: CancellationToken) -> Result<FetchedContent> {
        let run = self.fetch_inner(url, &cancel);
        tokio::select! { biased;
            _ = cancel.cancelled() => Err(Error::Cancelled),
            result = tokio::time::timeout(Duration::from_secs(30), run) => result.map_err(|_| failure())?,
        }
    }
    async fn fetch_inner(&self, text: &str, cancel: &CancellationToken) -> Result<FetchedContent> {
        let mut url = public_url(text)?;
        for redirects in 0..=3 {
            check_cancel(cancel)?;
            let host = url.host_str().ok_or_else(failure)?.trim_matches(['[', ']']);
            let addresses = self.resolver.resolve(host).await?;
            if addresses.is_empty()
                || addresses.len() > 64
                || addresses
                    .iter()
                    .any(|a| a.port() != 443 || !public_address(a.ip()))
            {
                return Err(failure());
            }
            let response = self.transport.get(&url, &addresses, cancel.clone()).await?;
            if [301, 302, 303, 307, 308].contains(&response.status) {
                if redirects == 3 {
                    return Err(failure());
                }
                let mut target = url
                    .join(response.location.as_deref().ok_or_else(failure)?)
                    .map_err(|_| failure())?;
                if target.scheme() == "http" {
                    if target.port_or_known_default() != Some(80) {
                        return Err(failure());
                    }
                    target.set_scheme("https").map_err(|_| failure())?;
                    target.set_port(None).map_err(|_| failure())?;
                }
                url = public_url(target.as_str())?;
                continue;
            }
            if !(200..300).contains(&response.status) {
                return Err(failure());
            }
            let mime = response
                .content_type
                .split(';')
                .next()
                .unwrap_or("")
                .trim()
                .to_ascii_lowercase();
            if !mime.starts_with("text/")
                && ![
                    "application/json",
                    "application/xml",
                    "application/xhtml+xml",
                ]
                .contains(&mime.as_str())
            {
                return Err(failure());
            }
            let mut bytes = Vec::new();
            let mut body = response.body;
            while let Some(chunk) = body.next().await {
                check_cancel(cancel)?;
                let chunk = chunk?;
                if bytes.len() + chunk.len() > BODY_LIMIT {
                    return Err(failure());
                }
                bytes.extend_from_slice(&chunk);
            }
            let parse_mime = mime.clone();
            let (text, truncated) =
                tokio::task::spawn_blocking(move || extract_text(&bytes, &parse_mime))
                    .await
                    .map_err(|_| failure())??;
            check_cancel(cancel)?;
            return Ok(FetchedContent {
                url: url.into(),
                content_type: mime,
                text,
                truncated,
            });
        }
        Err(failure())
    }
}
pub fn extract_text(bytes: &[u8], mime: &str) -> Result<(String, bool)> {
    let source = std::str::from_utf8(bytes).map_err(|_| failure())?;
    if source.contains('\0') {
        return Err(failure());
    }
    let text = if ["text/html", "application/xhtml+xml"].contains(&mime) {
        let html = scraper::Html::parse_document(source);
        let mut text = String::new();
        for (index, node) in html.root_element().descendants().enumerate() {
            if index >= 400000 {
                return Err(failure());
            }
            if let scraper::node::Node::Text(value) = node.value() {
                let mut ancestors = node.ancestors();
                let mut hidden = false;
                for ancestor in ancestors.by_ref().take(256) {
                    if let scraper::node::Node::Element(element) = ancestor.value()
                        && ["script", "style", "noscript", "template", "svg", "head"]
                            .contains(&element.name())
                    {
                        hidden = true;
                        break;
                    }
                }
                if !hidden && ancestors.next().is_some() {
                    return Err(failure());
                }
                if !hidden {
                    text.push_str(value);
                    text.push(' ');
                }
            }
        }
        text.split_whitespace().collect::<Vec<_>>().join(" ")
    } else {
        source.to_owned()
    };
    if text.trim().is_empty() {
        return Err(failure());
    }
    let truncated = text.len() > TEXT_LIMIT;
    let mut text = text;
    let mut end = TEXT_LIMIT.min(text.len());
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text.truncate(end);
    Ok((text, truncated))
}
