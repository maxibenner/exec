//! Neutral immutable image references. Encoded payloads exist only at provider/asset boundaries.
use crate::{Error, Result};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ImageRef {
    pub id: String,
    pub name: String,
    pub media_type: String,
    pub width: u32,
    pub height: u32,
    pub byte_count: usize,
    pub sha256: String,
}
impl ImageRef {
    pub fn validate(&self) -> Result<()> {
        if !super::valid_id(&self.id)
            || self.name.is_empty()
            || self.name.len() > 256
            || self.name.chars().any(char::is_control)
            || !["image/png", "image/jpeg"].contains(&self.media_type.as_str())
            || self.width == 0
            || self.height == 0
            || self.width > 8192
            || self.height > 8192
            || u64::from(self.width) * u64::from(self.height) > 32_000_000
            || self.byte_count == 0
            || self.byte_count > 8 * 1024 * 1024
            || self.sha256.len() != 64
            || !self.sha256.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Err(Error::Invalid("Invalid image reference."));
        }
        Ok(())
    }
}
#[derive(Clone)]
pub struct ImageInput {
    pub media_type: String,
    pub base64: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ImageData {
    pub image: ImageRef,
    pub base64: String,
}
#[async_trait]
pub trait ImageReader: Send + Sync {
    async fn load(&self, image: &ImageRef) -> Result<ImageInput>;
}
#[derive(Clone)]
pub struct GeneratedImage {
    pub bytes: Vec<u8>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ImageGeneration {
    pub prompt: String,
    pub transparent_background: bool,
}
impl ImageGeneration {
    pub fn validate(&self) -> Result<()> {
        if self.prompt.trim().is_empty()
            || self.prompt.len() > 16 * 1024
            || self.prompt.contains('\0')
        {
            return Err(Error::Invalid(
                "Image prompt must be nonempty and at most 16 KiB.",
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WindowInfo {
    pub id: u32,
    pub title: String,
}
