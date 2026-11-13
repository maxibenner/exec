use super::edit_diff::edit_diff;
use super::{workspace::*, *};
use crate::{
    check_cancel,
    storage::{same_file, unchanged},
};
use serde_json::json;
use std::{
    fs::{self, OpenOptions, Permissions},
    io::Write,
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::Path,
    sync::Mutex,
    time::{Duration, Instant},
};
static WRITES: Mutex<()> = Mutex::new(());
#[derive(Clone, Copy)]
enum FileTool {
    List,
    Read,
    Search,
    Edit,
}
pub fn create_file_tools() -> Vec<Arc<dyn Tool>> {
    [
        FileTool::List,
        FileTool::Read,
        FileTool::Search,
        FileTool::Edit,
    ]
    .into_iter()
    .map(|t| Arc::new(t) as Arc<dyn Tool>)
    .collect()
}
#[async_trait]
impl Tool for FileTool {
    fn definition(&self) -> ToolDefinition {
        let (name, description, properties, required) = match self {
            Self::List => (
                "list_files",
                "List one workspace directory. Symlinks are not followed. Output is bounded.",
                json!({"path":{"type":"string"}}),
                vec!["path"],
            ),
            Self::Read => (
                "read_file",
                "Read 1–400 lines of a UTF-8 file up to 1 MiB, with its full-file revision. Output is bounded to 32 KiB.",
                json!({"path":{"type":"string"},"start_line":{"type":"integer","minimum":1},"end_line":{"type":"integer","minimum":1}}),
                vec!["path", "start_line", "end_line"],
            ),
            Self::Search => (
                "search_text",
                "Bounded case-sensitive literal search. Skips hidden entries, node_modules, dist, symlinks, binary and oversized files; reports incomplete searches.",
                json!({"path":{"type":"string"},"query":{"type":"string","minLength":1}}),
                vec!["path", "query"],
            ),
            Self::Edit => (
                "edit_file",
                "Propose one exact replacement, requiring approval. Read first and supply its revision. For creation, use expected_revision 'new' and empty old_text; parent must exist.",
                json!({"path":{"type":"string"},"expected_revision":{"type":"string"},"old_text":{"type":"string"},"new_text":{"type":"string"}}),
                vec!["path", "expected_revision", "old_text", "new_text"],
            ),
        };
        ToolDefinition {
            name: name.into(),
            description: description.into(),
            parameters: schema(properties, &required),
        }
    }
    async fn prepare(
        &self,
        args: Arguments,
        context: ToolContext,
    ) -> Result<Box<dyn PreparedTool>> {
        let kind = *self;
        blocking(move || {
            let allowed = match kind {
                Self::List => vec!["path"],
                Self::Read => vec!["path", "start_line", "end_line"],
                Self::Search => vec!["path", "query"],
                Self::Edit => vec!["path", "expected_revision", "old_text", "new_text"],
            };
            fields(&args, &allowed)?;
            let path = relative_path(&string(&args, "path", 4096)?)?;
            let workspace = Workspace::new(&context.workspace, context.cancel)?;
            if matches!(kind, Self::Edit) {
                return prepare_edit(args, path, workspace);
            }
            let (start, end) = if matches!(kind, Self::Read) {
                let start = integer(&args, "start_line", 1, 9_007_199_254_740_991, None)?;
                (
                    start,
                    integer(
                        &args,
                        "end_line",
                        start,
                        (start + 399).min(9_007_199_254_740_991),
                        None,
                    )?,
                )
            } else {
                (0, 0)
            };
            let query = if matches!(kind, Self::Search) {
                let q = string(&args, "query", 4096)?;
                if q.is_empty() || q.contains(['\r', '\n']) {
                    return Err(failure("Search requires a nonempty single-line literal."));
                }
                q
            } else {
                String::new()
            };
            Ok(Box::new(Action {
                resources: vec![],
                details: None,
                approval: None,
                execute: Box::new(move || {
                    Box::pin(blocking(move || match kind {
                        Self::List => list(&workspace, &path),
                        Self::Read => read(&workspace, &path, start as usize, end as usize),
                        Self::Search => search(&workspace, &path, &query),
                        Self::Edit => unreachable!(),
                    }))
                }),
            }) as Box<dyn PreparedTool>)
        })
        .await
    }
}
fn quoted(s: &str) -> String {
    serde_json::to_string(s).unwrap()
}
fn prepare_edit(
    args: Arguments,
    path: String,
    workspace: Workspace,
) -> Result<Box<dyn PreparedTool>> {
    if path == "." {
        return Err(failure("Choose a file, not the workspace root."));
    }
    let expected = string(&args, "expected_revision", 64)?;
    let old = string(&args, "old_text", 32768)?;
    let new = string(&args, "new_text", 32768)?;
    let (_, initial) = workspace.path(&path, true)?;
    let before = if initial.is_some() {
        Some(workspace.read(&path)?)
    } else {
        None
    };
    if let Some(before) = &before {
        if expected != revision(&before.data) {
            return Err(failure(
                "Revision mismatch. Read the file again before proposing an edit. Nothing was written.",
            ));
        }
        if before.info.mode() & 0o6000 != 0 || before.info.nlink() != 1 {
            return Err(failure("Cannot edit set-ID or multiply linked files."));
        }
    } else if expected != "new" || !old.is_empty() {
        return Err(failure(
            "Creation requires expected_revision 'new', empty old_text, and an existing parent directory.",
        ));
    }
    let original = if let Some(before) = &before {
        text(&before.data)?
    } else {
        ""
    };
    let after = if old.is_empty() {
        if !original.is_empty() {
            return Err(failure(
                "old_text must match one nonempty block in an existing file.",
            ));
        }
        new.clone()
    } else {
        let Some(index) = original.find(&old) else {
            return Err(failure(
                "old_text must match exactly once, including overlapping matches.",
            ));
        };
        // Search byte windows so overlapping matches are rejected too.
        if original.as_bytes()[index + 1..]
            .windows(old.len())
            .any(|w| w == old.as_bytes())
        {
            return Err(failure(
                "old_text must match exactly once, including overlapping matches.",
            ));
        }
        format!(
            "{}{}{}",
            &original[..index],
            new,
            &original[index + old.len()..]
        )
    };
    let (diff, truncated) = edit_diff(&path, original, &after);
    let details = Some(ToolDetails::Edit {
        path: path.clone(),
        diff,
        truncated,
    });
    let data = after.into_bytes();
    if data.len() > FILE_LIMIT || before.as_ref().is_some_and(|b| b.data == data) {
        return Err(failure("Edit is unchanged or exceeds 1 MiB."));
    }
    let approval = format!(
        "{} {}\nRevision: {expected}\nReplace exact text:\n{}\nWith:\n{}{}",
        if before.is_some() { "Edit" } else { "Create" },
        quoted(&path),
        quoted(&old),
        quoted(&new),
        if before.is_some() {
            "\nMetadata: preserves POSIX owner/group/mode only; ACLs and extended attributes are not retained."
        } else {
            ""
        }
    );
    if approval.len() > 65536 {
        return Err(failure("Approval exceeds 64 KiB. Propose a smaller edit."));
    }
    Ok(Box::new(Action {
        resources: vec![],
        details,
        approval: Some(approval),
        execute: Box::new(move || {
            Box::pin(blocking(move || {
                let _guard = WRITES.lock().map_err(|_| Error::Internal)?;
                check_cancel(&workspace.cancel)?;
                let parent_relative = Path::new(&path)
                    .parent()
                    .and_then(|p| p.to_str())
                    .filter(|p| !p.is_empty())
                    .unwrap_or(".");
                let (parent, parent_info) = workspace.path(parent_relative, false)?;
                let staged = parent.join(format!(".exec-edit-{}", new_id()));
                let mut file = OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .custom_flags(libc::O_NOFOLLOW)
                    .mode(0o600)
                    .open(&staged)?;
                let result = (|| {
                    file.write_all(&data)?;
                    if let Some(before) = &before {
                        std::os::unix::fs::chown(
                            &staged,
                            Some(before.info.uid()),
                            Some(before.info.gid()),
                        )?;
                        file.set_permissions(Permissions::from_mode(before.info.mode() & 0o777))?;
                    }
                    file.sync_all()?;
                    let (target, current) = workspace.path(&path, true)?;
                    if let Some(before) = &before {
                        if current.is_none() {
                            return Err(failure(
                                "File disappeared while approval was pending. Nothing was written to the target.",
                            ));
                        }
                        let latest = workspace.read(&path)?;
                        if !unchanged(&before.info, &latest.info) || before.data != latest.data {
                            return Err(failure(
                                "File changed while approval was pending. Nothing was written to the target; read it again.",
                            ));
                        }
                    } else if current.is_some() {
                        return Err(failure(
                            "New file path is no longer available. Nothing was overwritten.",
                        ));
                    }
                    let (_, latest_parent) = workspace.path(parent_relative, false)?;
                    if !same_file(
                        parent_info.as_ref().unwrap(),
                        latest_parent.as_ref().unwrap(),
                    ) {
                        return Err(failure(
                            "Parent directory changed. Nothing was written to the target.",
                        ));
                    }
                    check_cancel(&workspace.cancel)?;
                    if before.is_some() {
                        fs::rename(&staged, &target)?;
                    } else {
                        fs::hard_link(&staged, &target)?;
                    }
                    Ok(format!(
                        "Edited {}. Revision: {}",
                        quoted(&path),
                        revision(&data)
                    ))
                })();
                let _ = fs::remove_file(staged);
                result
            }))
        }),
    }))
}
fn list(workspace: &Workspace, path: &str) -> Result<String> {
    let (names, mut truncated) = workspace.entries(path)?;
    let (directory, _) = workspace.path(path, false)?;
    let mut output = String::new();
    for name in names {
        check_cancel(&workspace.cancel)?;
        let info = fs::symlink_metadata(directory.join(&name))?;
        let line = format!(
            "{}{}\n",
            quoted(&name),
            if info.is_dir() {
                "/"
            } else if info.file_type().is_symlink() {
                " [symlink; not followed]"
            } else {
                ""
            }
        );
        if output.len() + line.len() > OUTPUT_LIMIT - 256 {
            truncated = true;
            break;
        }
        output.push_str(&line);
    }
    if output.is_empty() {
        output.push_str("(empty directory)\n");
    }
    if truncated {
        output.push_str("[Listing truncated; choose a narrower directory.]");
    }
    Ok(output)
}
fn read(workspace: &Workspace, path: &str, start: usize, end: usize) -> Result<String> {
    let file = workspace.read(path)?;
    let lines: Vec<_> = text(&file.data)?.split('\n').collect();
    let mut output = format!("Revision: {}\n", revision(&file.data));
    if start > lines.len() {
        output.push_str(&format!(
            "Requested range is past end of file ({} lines).",
            lines.len()
        ));
        return Ok(output);
    }
    for (index, line) in lines.iter().enumerate().take(end).skip(start - 1) {
        let line = format!("{}: {line}\n", index + 1);
        if output.len() + line.len() > OUTPUT_LIMIT - 128 {
            output.push_str("[Output truncated at 32 KiB.]");
            break;
        }
        output.push_str(&line);
    }
    Ok(output)
}
fn search(workspace: &Workspace, path: &str, query: &str) -> Result<String> {
    if !workspace.path(path, false)?.1.unwrap().is_dir() {
        return Err(failure("Choose a search directory."));
    }
    let mut pending = vec![(path.to_owned(), 0)];
    let mut visited = 0;
    let mut matches = 0;
    let mut output = String::new();
    let mut incomplete = false;
    let start = Instant::now();
    'scan: while let Some((directory, depth)) = pending.pop() {
        check_cancel(&workspace.cancel)?;
        if visited >= 2000 || start.elapsed() >= Duration::from_secs(5) {
            incomplete = true;
            break;
        }
        let (names, truncated) = match workspace.entries(&directory) {
            Ok(v) => v,
            Err(_) => {
                check_cancel(&workspace.cancel)?;
                incomplete = true;
                continue;
            }
        };
        incomplete |= truncated;
        for name in names {
            check_cancel(&workspace.cancel)?;
            visited += 1;
            if visited > 2000 || start.elapsed() >= Duration::from_secs(5) {
                incomplete = true;
                break 'scan;
            }
            if name.starts_with('.') || name == "node_modules" || name == "dist" {
                continue;
            }
            let child = if directory == "." {
                name
            } else {
                format!("{directory}/{name}")
            };
            let scan = (|| -> Result<bool> {
                if workspace.path(&child, false)?.1.unwrap().is_dir() {
                    if depth < 16 {
                        pending.push((child, depth + 1));
                    } else {
                        incomplete = true;
                    }
                    return Ok(false);
                }
                let file = workspace.read(&child)?;
                for (index, line) in text(&file.data)?.split('\n').enumerate() {
                    if !line.contains(query) {
                        continue;
                    }
                    let line = format!("{}:{}: {line}\n", quoted(&child), index + 1);
                    if matches >= 100 || output.len() + line.len() > OUTPUT_LIMIT - 256 {
                        return Ok(true);
                    }
                    output.push_str(&line);
                    matches += 1;
                }
                Ok(false)
            })();
            match scan {
                Ok(true) => {
                    incomplete = true;
                    break 'scan;
                }
                Err(_) => {
                    check_cancel(&workspace.cancel)?;
                    incomplete = true;
                }
                _ => {}
            }
        }
    }
    if output.is_empty() {
        output.push_str("No matches in searched files.\n");
    }
    if incomplete {
        output.push_str("[Search incomplete: limits reached or unreadable, oversized, binary, or linked files skipped.]");
    }
    Ok(output)
}
