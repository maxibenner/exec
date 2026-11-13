use super::{workspace::Workspace, *};
use crate::check_cancel;
use serde_json::json;
use std::{process::Stdio, sync::Mutex, time::Duration};
use tokio::{
    io::{AsyncRead, AsyncReadExt},
    process::Command,
};
use tokio_util::sync::CancellationToken;
struct ShellTool;
pub fn create_shell_tool() -> Arc<dyn Tool> {
    Arc::new(ShellTool)
}
#[async_trait]
impl Tool for ShellTool {
    fn definition(&self) -> ToolDefinition {
        ToolDefinition{name:"shell".into(),description:"Run an approved bash command in the workspace (not sandboxed), with bounded combined output. Default timeout 120 seconds, maximum 900. Commands are not retried; background jobs are terminated on completion.".into(),parameters:schema(json!({"command":{"type":"string","minLength":1},"timeout_seconds":{"type":"integer","minimum":1,"maximum":900}}),&["command"])}
    }
    async fn prepare(
        &self,
        args: Arguments,
        context: ToolContext,
    ) -> Result<Box<dyn PreparedTool>> {
        fields(&args, &["command", "timeout_seconds"])?;
        let command = string(&args, "command", 32768)?;
        if command.trim().is_empty() {
            return Err(failure("Command must not be empty."));
        }
        let timeout = integer(&args, "timeout_seconds", 1, 900, Some(120))?;
        let workspace =
            blocking(move || Workspace::new(&context.workspace, context.cancel)).await?;
        let approval = format!(
            "Command:\n{command}\n\nDirectory: {}\nTimeout: {timeout} seconds",
            serde_json::to_string(&workspace.root.to_string_lossy()).unwrap()
        );
        Ok(Box::new(Action {
            approval: Some(approval),
            execute: Box::new(move || {
                Box::pin(async move {
                    let workspace = blocking(move || {
                        workspace.path(".", false)?;
                        Ok(workspace)
                    })
                    .await?;
                    run(command, workspace.root, timeout, workspace.cancel).await
                })
            }),
        }))
    }
}
#[derive(Default)]
struct Capture {
    first: Vec<u8>,
    last: Vec<u8>,
    size: usize,
}
impl Capture {
    fn append(&mut self, data: &[u8]) {
        self.size += data.len();
        self.first
            .extend_from_slice(&data[..data.len().min(15000 - self.first.len())]);
        self.last.extend_from_slice(data);
        if self.last.len() > 15000 {
            self.last.drain(..self.last.len() - 15000);
        }
    }
    fn text(&self) -> String {
        if self.size <= 30000 {
            let remainder = self.size - self.first.len();
            let mut all = self.first.clone();
            all.extend_from_slice(&self.last[self.last.len() - remainder..]);
            String::from_utf8_lossy(&all).into_owned()
        } else {
            format!(
                "{}\n[Output truncated: captured first/last 15,000 bytes of {} bytes. Full output was not retained.]\n{}",
                String::from_utf8_lossy(&self.first),
                self.size,
                String::from_utf8_lossy(&self.last)
            )
        }
    }
}
async fn drain(
    mut pipe: impl AsyncRead + Unpin,
    capture: Arc<Mutex<Capture>>,
) -> std::io::Result<()> {
    let mut data = [0; 8192];
    loop {
        let size = pipe.read(&mut data).await?;
        if size == 0 {
            return Ok(());
        }
        capture.lock().unwrap().append(&data[..size]);
    }
}
fn kill_group(pid: u32, signal: i32) -> bool {
    // SAFETY: kill takes scalar values only; the negative child PID identifies
    // the process group created for this invocation, never the service's group.
    let result = unsafe { libc::kill(-(pid as i32), signal) };
    result == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
}
async fn run(
    command: String,
    cwd: std::path::PathBuf,
    timeout: u64,
    cancel: CancellationToken,
) -> Result<String> {
    check_cancel(&cancel)?;
    let mut builder = Command::new("/bin/bash");
    builder
        .args(["--noprofile", "--norc", "-c", &command])
        .current_dir(cwd)
        .env_clear()
        .env(
            "PATH",
            "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        )
        .env("HOME", std::env::home_dir().unwrap_or_default())
        .env("TMPDIR", std::env::temp_dir())
        .env("LANG", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    builder.process_group(0);
    // SAFETY: this child-only pre-exec hook calls only async-signal-safe POSIX
    // functions with initialized local storage. No allocation or locking occurs.
    unsafe {
        builder.pre_exec(|| {
            let mut set = std::mem::zeroed::<libc::sigset_t>();
            libc::sigemptyset(&mut set);
            if libc::sigprocmask(libc::SIG_SETMASK, &set, std::ptr::null_mut()) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = builder
        .spawn()
        .map_err(|_| failure("Could not start the shell command.\n(no output)"))?;
    let pid = child.id().unwrap();
    let capture = Arc::new(Mutex::new(Capture::default()));
    let mut out = tokio::spawn(drain(child.stdout.take().unwrap(), capture.clone()));
    let mut err = tokio::spawn(drain(child.stderr.take().unwrap(), capture.clone()));
    let mut reason = None;
    let mut status = tokio::select! {
        biased;
        _=cancel.cancelled()=>{reason=Some("Command interrupted; it may have had effects.");None},
        _=tokio::time::sleep(Duration::from_secs(timeout))=>{reason=Some("Command timed out; it may have had effects.");None},
        status=child.wait()=>Some(status),
    };
    if status.is_none() {
        if !kill_group(pid, libc::SIGTERM) {
            reason = Some("Command cleanup failed; descendants may still be running.");
        }
        // Reap a cooperative parent during grace, but retain ownership until
        // escalation cleans descendants. macOS can report EPERM for a group
        // containing only the unreaped parent, rather than ESRCH.
        let grace = tokio::time::sleep(Duration::from_millis(250));
        tokio::pin!(grace);
        tokio::select! {exit=child.wait()=>{status=Some(exit);grace.await;},_=&mut grace=>{}}
    }
    if !kill_group(pid, libc::SIGKILL) {
        reason = Some("Command cleanup failed; descendants may still be running.");
    }
    let status = match status {
        Some(status) => status,
        None => child.wait().await,
    };
    let drained = tokio::time::timeout(Duration::from_secs(1), async {
        tokio::join!(&mut out, &mut err)
    })
    .await;
    if !matches!(drained, Ok((Ok(Ok(())), Ok(Ok(()))))) {
        reason = Some("Command cleanup failed; descendants may still be running.");
        out.abort();
        err.abort();
    }
    use std::os::unix::process::ExitStatusExt;
    let success = status.as_ref().is_ok_and(|s| s.success());
    let heading = if let Some(reason) = reason {
        reason.to_owned()
    } else if success {
        "Exit code: 0".into()
    } else {
        format!(
            "Command failed. Exit code: {}; signal: {}. It may have had effects.",
            status
                .as_ref()
                .ok()
                .and_then(|s| s.code())
                .map_or("none".into(), |s| s.to_string()),
            status
                .as_ref()
                .ok()
                .and_then(|s| s.signal())
                .map_or("none".into(), |s| s.to_string())
        )
    };
    let output = capture.lock().unwrap().text();
    let result = format!(
        "{heading}\n{}",
        if output.is_empty() {
            "(no output)"
        } else {
            &output
        }
    );
    if reason.is_some() || !success {
        Err(failure(result))
    } else {
        Ok(result)
    }
}
