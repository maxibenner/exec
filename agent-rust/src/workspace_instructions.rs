//! Manager-owned first-turn workspace instruction loading. Never run by the provider.
use crate::{
    Error, Result,
    core::{INSTRUCTION_LIMIT, validate_instructions},
};
use std::{
    fs::{File, OpenOptions},
    io::Read,
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::fs::OpenOptionsExt,
    },
    path::Path,
};

pub(crate) async fn load(root: String) -> Result<Option<String>> {
    tokio::task::spawn_blocking(move || read(&root))
        .await.map_err(|_| Error::Internal)?
        .map_err(|_| Error::Invalid("Could not read workspace AGENTS.md. It must be a regular UTF-8 file without NUL bytes, at most 64 KiB; symlinks are not followed."))
}
fn read(root: &str) -> Result<Option<String>> {
    if !Path::new(root).is_absolute() {
        return Err(Error::Internal);
    }
    let directory = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(root)?;
    // SAFETY: directory remains open; the literal is NUL-terminated. A successful
    // descriptor is transferred exactly once to File, which closes it on all paths.
    let descriptor = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            c"AGENTS.md".as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if descriptor < 0 {
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::NotFound {
            return Ok(None);
        }
        return Err(error.into());
    }
    let file = unsafe { File::from_raw_fd(descriptor) };
    let before = file.metadata()?;
    if !before.is_file() || before.len() > INSTRUCTION_LIMIT as u64 {
        return Err(Error::Internal);
    }
    let mut bytes = Vec::new();
    (&file)
        .take((INSTRUCTION_LIMIT + 1) as u64)
        .read_to_end(&mut bytes)?;
    if !crate::storage::unchanged(&before, &file.metadata()?) {
        return Err(Error::Internal);
    }
    let text = String::from_utf8(bytes).map_err(|_| Error::Internal)?;
    validate_instructions(&text)?;
    Ok(Some(text))
}
