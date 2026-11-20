//! Shared standalone-server and local-administration credential configuration.
use crate::{Error, Result};
use rand::RngCore;
use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
};

const INVALID: &str = "Use either EXEC_AGENT_TOKEN or an owned, private EXEC_AGENT_TOKEN_FILE containing 64 hexadecimal characters.";

enum TokenInput {
    Environment(String),
    File(PathBuf),
}
fn input() -> Result<Option<TokenInput>> {
    configured_input(
        std::env::var("EXEC_AGENT_TOKEN"),
        std::env::var("EXEC_AGENT_TOKEN_FILE"),
        std::env::var("EXEC_AGENT_DEFAULT_TOKEN_FILE"),
    )
}
fn configured_input(
    token: std::result::Result<String, std::env::VarError>,
    file: std::result::Result<String, std::env::VarError>,
    default_file: std::result::Result<String, std::env::VarError>,
) -> Result<Option<TokenInput>> {
    fn value(value: std::result::Result<String, std::env::VarError>) -> Result<Option<String>> {
        match value {
            Ok(value) => Ok(Some(value)),
            Err(std::env::VarError::NotPresent) => Ok(None),
            Err(_) => Err(Error::Invalid(INVALID)),
        }
    }
    fn file_input(path: String) -> Result<TokenInput> {
        if !Path::new(&path).is_absolute() {
            return Err(Error::Invalid(INVALID));
        }
        Ok(TokenInput::File(path.into()))
    }
    // An image default is only a location, not a second explicit credential source.
    // Empty or invalid explicit settings still fail closed; never fall back from them.
    match (value(token)?, value(file)?) {
        (Some(token), None) => Ok(Some(TokenInput::Environment(validate(&token)?))),
        (None, Some(file)) => file_input(file).map(Some),
        (None, None) => value(default_file)?.map(file_input).transpose(),
        _ => Err(Error::Invalid(INVALID)),
    }
}
fn validate(value: &str) -> Result<String> {
    if value.len() != 64 || !value.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(Error::Invalid(INVALID));
    }
    Ok(value.to_owned())
}
fn read_token(path: &Path) -> Result<Option<String>> {
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(Error::Invalid(INVALID)),
    };
    let metadata = file.metadata().map_err(|_| Error::Invalid(INVALID))?;
    // SAFETY: getuid has no preconditions.
    if !metadata.is_file()
        || metadata.uid() != unsafe { libc::getuid() }
        || metadata.mode() & 0o077 != 0
        || metadata.len() > 66
    {
        return Err(Error::Invalid(INVALID));
    }
    let mut value = String::new();
    file.take(67)
        .read_to_string(&mut value)
        .map_err(|_| Error::Invalid(INVALID))?;
    let value = value
        .strip_suffix("\r\n")
        .or_else(|| value.strip_suffix('\n'))
        .unwrap_or(&value);
    validate(value).map(Some)
}

/// Read a provisioned token, without generating, repairing or rotating credentials.
pub fn api_token() -> Result<Option<String>> {
    match input()? {
        None => Ok(None),
        Some(TokenInput::Environment(value)) => Ok(Some(value)),
        Some(TokenInput::File(path)) => read_token(&path)?.map(Some).ok_or(Error::Invalid(INVALID)),
    }
}

/// Initialize a missing private token file once. Existing credentials never change.
pub fn initialize_api_token() -> Result<()> {
    match input()? {
        Some(TokenInput::Environment(_)) => Ok(()),
        Some(TokenInput::File(path)) => initialize_file(&path),
        None => Err(Error::Invalid(INVALID)),
    }
}
fn initialize_file(path: &Path) -> Result<()> {
    if read_token(path)?.is_some() {
        return Ok(());
    }
    let parent = path.parent().ok_or(Error::Invalid(INVALID))?;
    let metadata = fs::symlink_metadata(parent).map_err(|_| Error::Invalid(INVALID))?;
    // Never repair permissions or follow a linked parent while provisioning a credential.
    if !metadata.is_dir()
        || metadata.uid() != unsafe { libc::getuid() }
        || metadata.mode() & 0o077 != 0
    {
        return Err(Error::Invalid(INVALID));
    }
    let temporary = parent.join(format!(".admin-token.{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| -> Result<()> {
        let mut bytes = [0u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut bytes);
        let token: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(token.as_bytes())?;
        file.sync_all()?;
        // Atomic create-only publication: no empty token window and no replacement.
        match fs::hard_link(&temporary, path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                read_token(path)?.ok_or(Error::Invalid(INVALID))?;
            }
            Err(error) => return Err(error.into()),
        }
        fs::File::open(parent)?.sync_all()?;
        Ok(())
    })();
    let _ = fs::remove_file(temporary);
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};

    #[test]
    fn configuration_distinguishes_defaults_from_explicit_sources() {
        let absent = || Err(std::env::VarError::NotPresent);
        let default = || Ok("/private/default-token".into());
        assert!(matches!(
            configured_input(Ok("ab".repeat(32)), absent(), default()).unwrap(),
            Some(TokenInput::Environment(_))
        ));
        assert!(matches!(
            configured_input(absent(), Ok("/private/token".into()), default()).unwrap(),
            Some(TokenInput::File(path)) if path == Path::new("/private/token")
        ));
        assert!(matches!(
            configured_input(absent(), absent(), default()).unwrap(),
            Some(TokenInput::File(path)) if path == Path::new("/private/default-token")
        ));
        assert!(
            configured_input(absent(), absent(), absent())
                .unwrap()
                .is_none()
        );
        for file in ["/private/token", "", "relative/token"] {
            assert!(configured_input(Ok("ab".repeat(32)), Ok(file.into()), default()).is_err());
        }
        assert!(configured_input(Ok(String::new()), absent(), default()).is_err());
        for invalid in ["", "relative/token"] {
            assert!(configured_input(absent(), Ok(invalid.into()), default()).is_err());
            assert!(configured_input(absent(), absent(), Ok(invalid.into())).is_err());
        }
        let non_unicode = || {
            Err(std::env::VarError::NotUnicode(std::ffi::OsString::from(
                "invalid",
            )))
        };
        assert!(configured_input(non_unicode(), absent(), default()).is_err());
        assert!(configured_input(absent(), non_unicode(), default()).is_err());
        assert!(configured_input(absent(), absent(), non_unicode()).is_err());
        // An unused fallback cannot invalidate a correctly provisioned explicit token.
        assert!(configured_input(Ok("ab".repeat(32)), absent(), non_unicode()).is_ok());
    }
    #[test]
    fn initialization_is_private_and_never_rotates() {
        let directory = tempfile::tempdir().unwrap();
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory.path().join("token");
        initialize_file(&path).unwrap();
        let token = read_token(&path).unwrap().unwrap();
        assert_eq!(token.len(), 64);
        assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o600);
        initialize_file(&path).unwrap();
        assert_eq!(read_token(&path).unwrap().unwrap(), token);
        assert_eq!(fs::read_dir(directory.path()).unwrap().count(), 1);
    }
    #[test]
    fn insecure_invalid_and_linked_files_fail_without_repair() {
        let directory = tempfile::tempdir().unwrap();
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o755)).unwrap();
        let path = directory.path().join("token");
        assert!(initialize_file(&path).is_err());
        assert!(!path.exists());
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
        initialize_file(&path).unwrap();
        let original = fs::read(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(initialize_file(&path).is_err());
        assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o644);
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        let link = directory.path().join("link");
        symlink(&path, &link).unwrap();
        assert!(initialize_file(&link).is_err());
        fs::write(&path, b"incomplete").unwrap();
        assert!(initialize_file(&path).is_err());
        assert_eq!(fs::read(&path).unwrap(), b"incomplete");
        fs::write(&path, original).unwrap();
        let mut with_newline = fs::read_to_string(&path).unwrap();
        with_newline.push('\n');
        fs::write(&path, with_newline).unwrap();
        assert!(read_token(&path).unwrap().is_some());
    }
}
