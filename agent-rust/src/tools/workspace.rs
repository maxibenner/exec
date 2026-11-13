use super::failure;
use crate::{
    Result, check_cancel,
    storage::{same_file, unchanged},
};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, Metadata, OpenOptions},
    io::Read,
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
};
use tokio_util::sync::CancellationToken;
pub const FILE_LIMIT: usize = 1024 * 1024;
pub const OUTPUT_LIMIT: usize = 32 * 1024;
pub fn revision(data: &[u8]) -> String {
    format!("{:x}", Sha256::digest(data))
}
pub fn text(data: &[u8]) -> Result<&str> {
    if data.contains(&0) {
        return Err(failure(
            "File contains NUL bytes; only UTF-8 text is supported.",
        ));
    }
    std::str::from_utf8(data).map_err(|_| failure("File is not valid UTF-8 text."))
}
pub fn relative_path(path: &str) -> Result<String> {
    if path.is_empty()
        || Path::new(path).is_absolute()
        || path.contains(['\0', '\\'])
        || path.len() > 4096
        || path.split('/').any(|p| p == "..")
    {
        return Err(failure(
            "Use a relative workspace path without '..' or backslashes.",
        ));
    }
    let path = path
        .split('/')
        .filter(|p| !p.is_empty() && *p != ".")
        .collect::<Vec<_>>()
        .join("/");
    Ok(if path.is_empty() { ".".into() } else { path })
}
pub struct TextFile {
    pub data: Vec<u8>,
    pub info: Metadata,
}
pub struct Workspace {
    pub root: PathBuf,
    identity: Metadata,
    pub cancel: CancellationToken,
}
impl Workspace {
    pub fn new(root: &str, cancel: CancellationToken) -> Result<Self> {
        check_cancel(&cancel)?;
        if !Path::new(root).is_absolute() {
            return Err(failure("Workspace must be an absolute directory path."));
        }
        let root = fs::canonicalize(root)?;
        let identity = fs::symlink_metadata(&root)?;
        if !identity.is_dir() {
            return Err(failure("Workspace must be a directory."));
        }
        Ok(Self {
            root,
            identity,
            cancel,
        })
    }
    // Component checks plus O_NOFOLLOW match the TS boundary; external ancestor
    // replacement races remain possible. These tools are not a sandbox.
    pub fn path(&self, path: &str, allow_missing: bool) -> Result<(PathBuf, Option<Metadata>)> {
        check_cancel(&self.cancel)?;
        let relative = relative_path(path)?;
        let target = if relative == "." {
            self.root.clone()
        } else {
            self.root.join(relative)
        };
        let components: Vec<_> = target.components().collect();
        let mut current = PathBuf::new();
        let mut found = false;
        let mut info = None;
        for (index, part) in components.iter().enumerate() {
            check_cancel(&self.cancel)?;
            current.push(part.as_os_str());
            let metadata = match fs::symlink_metadata(&current) {
                Ok(info) => info,
                Err(e)
                    if allow_missing
                        && index + 1 == components.len()
                        && found
                        && e.kind() == std::io::ErrorKind::NotFound =>
                {
                    return Ok((target, None));
                }
                Err(e) => return Err(e.into()),
            };
            if metadata.file_type().is_symlink() {
                return Err(failure(
                    "Symlinks are not followed by workspace file tools.",
                ));
            }
            if index + 1 < components.len() && !metadata.is_dir() {
                return Err(failure("Parent path must be a directory."));
            }
            if current == self.root {
                if !same_file(&metadata, &self.identity) || !metadata.is_dir() {
                    return Err(failure("Workspace changed."));
                }
                found = true;
            }
            info = Some(metadata);
        }
        if !found {
            return Err(failure("Path is outside the workspace."));
        }
        Ok((target, info))
    }
    pub fn read(&self, path: &str) -> Result<TextFile> {
        let (pathbuf, checked) = self.path(path, false)?;
        let checked = checked.unwrap();
        if !checked.is_file() || checked.len() > FILE_LIMIT as u64 {
            return Err(failure(
                "Read requires a regular UTF-8 file of at most 1 MiB.",
            ));
        }
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(pathbuf)?;
        let info = file.metadata()?;
        if !info.is_file() || info.len() > FILE_LIMIT as u64 || !same_file(&info, &checked) {
            return Err(failure(
                "File changed or is not a regular file of at most 1 MiB.",
            ));
        }
        let mut data = vec![];
        (&file)
            .take((FILE_LIMIT + 1) as u64)
            .read_to_end(&mut data)?;
        check_cancel(&self.cancel)?;
        if data.len() > FILE_LIMIT {
            return Err(failure("File exceeds 1 MiB."));
        }
        let (_, latest) = self.path(path, false)?;
        if !unchanged(&info, &file.metadata()?)
            || latest.as_ref().is_none_or(|m| !unchanged(&info, m))
        {
            return Err(failure("File changed during reading; read it again."));
        }
        text(&data)?;
        Ok(TextFile { data, info })
    }
    pub fn entries(&self, path: &str) -> Result<(Vec<String>, bool)> {
        let (directory, info) = self.path(path, false)?;
        let info = info.unwrap();
        if !info.is_dir() {
            return Err(failure("Choose a directory."));
        }
        let mut names = vec![];
        let mut truncated = false;
        for entry in fs::read_dir(directory)? {
            check_cancel(&self.cancel)?;
            if names.len() == 2000 {
                truncated = true;
                break;
            }
            names.push(entry?.file_name().to_string_lossy().into_owned());
        }
        let (_, latest) = self.path(path, false)?;
        if latest.as_ref().is_none_or(|m| !same_file(&info, m)) {
            return Err(failure("Directory changed during listing."));
        }
        names.sort();
        Ok((names, truncated))
    }
}
