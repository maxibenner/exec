//! Read-only host directory selection. This is not a phone filesystem picker or
//! a file-content API; authenticated clients already control host workspace tools.
use crate::{Error, Result, check_cancel};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use tokio_util::sync::CancellationToken;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Browse {
    pub path: Option<String>,
    #[serde(default)]
    pub show_hidden: bool,
}
#[derive(Serialize)]
pub(crate) struct Directory {
    name: String,
    path: String,
}
#[derive(Serialize)]
pub(crate) struct Listing {
    path: String,
    parent: Option<String>,
    directories: Vec<Directory>,
    truncated: bool,
}
pub(crate) async fn browse(input: Browse, cancel: CancellationToken) -> Result<Listing> {
    let path = match input.path {
        Some(value) => {
            if value.len() > 4096 || value.contains('\0') || !Path::new(&value).is_absolute() {
                return Err(Error::Invalid(
                    "Use an absolute folder path on the agent host.",
                ));
            }
            PathBuf::from(value)
        }
        None => {
            std::env::home_dir().ok_or(Error::Invalid("The host home folder is unavailable."))?
        }
    };
    tokio::task::spawn_blocking(move || list(&path, input.show_hidden, &cancel))
        .await
        .map_err(|_| Error::Internal)?
}
fn list(path: &Path, show_hidden: bool, cancel: &CancellationToken) -> Result<Listing> {
    check_cancel(cancel)?;
    let path = std::fs::canonicalize(path)
        .map_err(|_| Error::Invalid("The host folder is unavailable or inaccessible."))?;
    let entries = std::fs::read_dir(&path)
        .map_err(|_| Error::Invalid("The host folder is unavailable or inaccessible."))?;
    let path_text = path
        .to_str()
        .ok_or(Error::Invalid("The folder path is not UTF-8."))?
        .to_owned();
    let mut directories = Vec::new();
    let mut truncated = false;
    for (index, entry) in entries.enumerate() {
        check_cancel(cancel)?;
        // Bound work and response size even on huge host directories.
        if index == 8192 || directories.len() == 512 {
            truncated = true;
            break;
        }
        let entry = entry.map_err(|_| Error::Invalid("Could not read this host folder."))?;
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        if !kind.is_dir() || kind.is_symlink() {
            continue;
        }
        let Ok(name) = entry.file_name().into_string() else {
            continue;
        };
        if (!show_hidden && name.starts_with('.')) || name.chars().any(char::is_control) {
            continue;
        }
        let Some(child) = entry
            .path()
            .to_str()
            .filter(|s| s.len() <= 4096)
            .map(str::to_owned)
        else {
            continue;
        };
        directories.push(Directory { name, path: child });
    }
    directories.sort_by(|a, b| {
        a.name
            .to_lowercase()
            .cmp(&b.name.to_lowercase())
            .then(a.name.cmp(&b.name))
    });
    Ok(Listing {
        parent: path.parent().and_then(Path::to_str).map(str::to_owned),
        path: path_text,
        directories,
        truncated,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn lists_only_directories_with_explicit_hidden_selection() {
        let root = tempfile::tempdir().unwrap();
        std::fs::create_dir(root.path().join("Project")).unwrap();
        std::fs::create_dir(root.path().join(".hidden")).unwrap();
        std::fs::write(root.path().join("file.txt"), "not exposed").unwrap();
        std::os::unix::fs::symlink(root.path().join("Project"), root.path().join("link")).unwrap();
        let result = browse(
            Browse {
                path: Some(root.path().to_str().unwrap().into()),
                show_hidden: false,
            },
            CancellationToken::new(),
        )
        .await
        .unwrap();
        assert_eq!(
            result
                .directories
                .iter()
                .map(|d| d.name.as_str())
                .collect::<Vec<_>>(),
            vec!["Project"]
        );
        assert!(!result.truncated);
        let hidden = browse(
            Browse {
                path: Some(root.path().to_str().unwrap().into()),
                show_hidden: true,
            },
            CancellationToken::new(),
        )
        .await
        .unwrap();
        assert_eq!(hidden.directories.len(), 2);
        assert!(
            browse(
                Browse {
                    path: Some("relative".into()),
                    show_hidden: false
                },
                CancellationToken::new()
            )
            .await
            .is_err()
        );
        let cancel = CancellationToken::new();
        cancel.cancel();
        assert!(
            browse(
                Browse {
                    path: Some(root.path().to_str().unwrap().into()),
                    show_hidden: false
                },
                cancel
            )
            .await
            .is_err()
        );
    }
}
