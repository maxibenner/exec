//! Private, immutable image assets; catalog references (including forks) own their lifetime.
use crate::{Error, Result, core::*};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, Metadata, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    path::PathBuf,
    sync::Arc,
};
#[derive(Clone)]
pub struct ImageStore {
    root: PathBuf,
    identity: Arc<Metadata>,
    validation: Arc<tokio::sync::Semaphore>,
}
fn failure() -> Error {
    Error::Invalid("Image storage is unavailable or image data is invalid.")
}
fn describe(id: String, name: String, bytes: &[u8]) -> Result<ImageRef> {
    if bytes.is_empty() || bytes.len() > 8 * 1024 * 1024 {
        return Err(failure());
    }
    let format = image::guess_format(bytes).map_err(|_| failure())?;
    if format == image::ImageFormat::Png
        && image::codecs::png::PngDecoder::new(std::io::Cursor::new(bytes))
            .map_err(|_| failure())?
            .is_apng()
            .map_err(|_| failure())?
    {
        return Err(failure());
    }
    let media = match format {
        image::ImageFormat::Png => "image/png",
        image::ImageFormat::Jpeg => "image/jpeg",
        _ => return Err(failure()),
    };
    let mut reader = image::ImageReader::with_format(std::io::Cursor::new(bytes), format);
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(8192);
    limits.max_image_height = Some(8192);
    limits.max_alloc = Some(256 * 1024 * 1024);
    reader.limits(limits);
    let (width, height) = image::ImageReader::with_format(std::io::Cursor::new(bytes), format)
        .into_dimensions()
        .map_err(|_| failure())?;
    if u64::from(width) * u64::from(height) > 32_000_000 {
        return Err(failure());
    }
    let decoded = reader.decode().map_err(|_| failure())?;
    if decoded.width() != width || decoded.height() != height {
        return Err(failure());
    }
    let image = ImageRef {
        id,
        name,
        media_type: media.into(),
        width,
        height,
        byte_count: bytes.len(),
        sha256: format!("{:x}", Sha256::digest(bytes)),
    };
    image.validate()?;
    Ok(image)
}
impl ImageStore {
    pub async fn open(root: PathBuf) -> Result<Arc<Self>> {
        tokio::task::spawn_blocking(move || {
            if !root.is_absolute() {
                return Err(failure());
            }
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(&root)?;
            let info = fs::symlink_metadata(&root)?;
            if !info.is_dir() || info.mode() & 0o077 != 0 || info.uid() != unsafe { libc::getuid() }
            {
                return Err(failure());
            }
            Ok(Arc::new(Self {
                root,
                identity: Arc::new(info),
                validation: Arc::new(tokio::sync::Semaphore::new(2)),
            }))
        })
        .await
        .map_err(|_| failure())?
    }
    fn check(&self) -> Result<()> {
        let info = fs::symlink_metadata(&self.root)?;
        if !info.is_dir()
            || info.mode() & 0o077 != 0
            || !crate::storage::same_file(&info, &self.identity)
        {
            return Err(failure());
        }
        Ok(())
    }
    fn path(&self, id: &str) -> Result<PathBuf> {
        if !valid_id(id) {
            return Err(failure());
        }
        Ok(self.root.join(format!("{id}.image")))
    }
    pub async fn put(&self, id: String, name: String, bytes: Vec<u8>) -> Result<ImageRef> {
        let permit = self
            .validation
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| failure())?;
        let store = self.clone();
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let image = describe(id.clone(), name, &bytes)?;
            store.check()?;
            let path = store.path(&id)?;
            // Publish only a fully synced immutable file. Interrupted staging is never promoted.
            let temp = store.root.join(format!(".{}.tmp", new_id()));
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temp)?;
            let result = (|| {
                file.write_all(&bytes)?;
                file.sync_all()?;
                store.check()?;
                fs::hard_link(&temp, &path)?;
                File::open(&store.root)?.sync_all()?;
                Ok(image)
            })();
            let _ = fs::remove_file(temp);
            result
        })
        .await
        .map_err(|_| failure())?
    }
    pub async fn read(&self, id: &str) -> Result<ImageData> {
        let permit = self
            .validation
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| failure())?;
        let store = self.clone();
        let path = self.path(id)?;
        let id = id.to_owned();
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            store.check()?;
            let file = OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
                .open(path)?;
            let before = file.metadata()?;
            if !before.is_file()
                || before.mode() & 0o077 != 0
                || before.uid() != unsafe { libc::getuid() }
                || before.len() > 8 * 1024 * 1024
            {
                return Err(failure());
            }
            let mut bytes = Vec::new();
            (&file).take(8 * 1024 * 1024 + 1).read_to_end(&mut bytes)?;
            if !crate::storage::unchanged(&before, &file.metadata()?) {
                return Err(failure());
            }
            let image = describe(id, "Image".into(), &bytes)?;
            Ok(ImageData {
                image,
                base64: B64.encode(bytes),
            })
        })
        .await
        .map_err(|_| failure())?
    }
    pub async fn delete(&self, ids: Vec<String>) -> Result<()> {
        let store = self.clone();
        tokio::task::spawn_blocking(move || {
            store.check()?;
            for id in ids {
                let path = store.path(&id)?;
                match fs::symlink_metadata(&path) {
                    Ok(info) if info.is_file() && info.uid() == unsafe { libc::getuid() } => {
                        fs::remove_file(path)?
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                    _ => return Err(failure()),
                }
            }
            File::open(&store.root)?.sync_all()?;
            Ok(())
        })
        .await
        .map_err(|_| failure())?
    }
}
#[async_trait::async_trait]
impl ImageReader for ImageStore {
    async fn load(&self, image: &ImageRef) -> Result<ImageInput> {
        image.validate()?;
        let data = self.read(&image.id).await?;
        if data.image.sha256 != image.sha256
            || data.image.width != image.width
            || data.image.height != image.height
            || data.image.media_type != image.media_type
            || data.image.byte_count != image.byte_count
        {
            return Err(failure());
        }
        Ok(ImageInput {
            media_type: image.media_type.clone(),
            base64: data.base64,
        })
    }
}
pub fn decode_base64(value: &str) -> Result<Vec<u8>> {
    if value.len() > 12 * 1024 * 1024 {
        return Err(failure());
    }
    let bytes = B64.decode(value).map_err(|_| failure())?;
    if bytes.len() > 8 * 1024 * 1024 {
        return Err(failure());
    }
    Ok(bytes)
}
