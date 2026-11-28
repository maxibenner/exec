use super::Result;
use std::{
    io::{IsTerminal, Write},
    mem::MaybeUninit,
    time::{Duration, Instant},
};
use tokio::signal::unix::{SignalKind, signal};
use tokio_util::sync::CancellationToken;

pub(super) const INTERRUPTED: &str = "Operation interrupted.";

pub(super) struct Signals {
    pub(super) cancel: CancellationToken,
    task: tokio::task::JoinHandle<()>,
}
impl Signals {
    pub(super) fn new() -> Result<Self> {
        let mut interrupt =
            signal(SignalKind::interrupt()).map_err(|_| "Cannot handle interrupts.")?;
        let mut terminate =
            signal(SignalKind::terminate()).map_err(|_| "Cannot handle interrupts.")?;
        let mut hangup = signal(SignalKind::hangup()).map_err(|_| "Cannot handle interrupts.")?;
        let cancel = CancellationToken::new();
        let notify = cancel.clone();
        let task = tokio::spawn(async move {
            tokio::select! {
                _ = interrupt.recv() => {},
                _ = terminate.recv() => {},
                _ = hangup.recv() => {},
            }
            notify.cancel();
        });
        Ok(Self { cancel, task })
    }
}
impl Drop for Signals {
    fn drop(&mut self) {
        self.task.abort();
    }
}

pub(super) fn require_interactive() -> Result<()> {
    if std::io::stdin().is_terminal() && std::io::stdout().is_terminal() {
        Ok(())
    } else {
        Err(
            "This operation requires interactive terminal stdin and stdout; sensitive output cannot be redirected.",
        )
    }
}

pub(super) fn check_key_input(from_stdin: bool) -> Result<()> {
    if from_stdin {
        if std::io::stdin().is_terminal() {
            return Err(
                "--key-stdin requires piped or file input, not a terminal; omit it for a hidden prompt.",
            );
        }
    } else if !std::io::stdin().is_terminal() || !std::io::stderr().is_terminal() {
        return Err(
            "Use --key-stdin explicitly for piped input, or use an interactive terminal for a hidden prompt.",
        );
    }
    Ok(())
}

struct HiddenInput(libc::termios);
impl HiddenInput {
    fn new() -> Result<Self> {
        let mut original = MaybeUninit::uninit();
        // SAFETY: tcgetattr initializes this termios on success; stdin was checked as a TTY.
        if unsafe { libc::tcgetattr(libc::STDIN_FILENO, original.as_mut_ptr()) } != 0 {
            return Err("Cannot disable terminal echo; no key was read.");
        }
        // SAFETY: tcgetattr succeeded.
        let original = unsafe { original.assume_init() };
        let mut hidden = original;
        hidden.c_lflag &= !(libc::ECHO | libc::ECHONL);
        // SAFETY: hidden is a valid termios for stdin. Discard pending input before the prompt.
        if unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSAFLUSH, &hidden) } != 0 {
            return Err("Cannot disable terminal echo; no key was read.");
        }
        Ok(Self(original))
    }
}
impl Drop for HiddenInput {
    fn drop(&mut self) {
        // SAFETY: restore the original termios and discard any unread credential input.
        unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSAFLUSH, &self.0) };
        let _ = writeln!(std::io::stderr());
    }
}

pub(super) async fn read_key(from_stdin: bool, cancel: CancellationToken) -> Result<String> {
    tokio::task::spawn_blocking(move || {
        let _hidden = if from_stdin {
            None
        } else {
            let guard = HiddenInput::new()?;
            write!(std::io::stderr(), "DeepSeek API key: ")
                .and_then(|_| std::io::stderr().flush())
                .map_err(|_| "Cannot write the key prompt.")?;
            Some(guard)
        };
        let deadline = Instant::now() + Duration::from_secs(60);
        let mut data = Vec::new();
        loop {
            if cancel.is_cancelled() {
                return Err(INTERRUPTED);
            }
            if Instant::now() >= deadline {
                return Err("Key input timed out; no request was sent.");
            }
            let mut descriptor = libc::pollfd {
                fd: libc::STDIN_FILENO,
                events: libc::POLLIN,
                revents: 0,
            };
            // SAFETY: descriptor is one initialized pollfd; polling bounds cancellation latency.
            let ready = unsafe { libc::poll(&mut descriptor, 1, 100) };
            if ready < 0 {
                if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return Err("Cannot read key input.");
            }
            if ready == 0 {
                continue;
            }
            if descriptor.revents & (libc::POLLERR | libc::POLLNVAL) != 0 {
                return Err("Cannot read key input.");
            }
            let mut buffer = [0u8; 512];
            // SAFETY: buffer is writable for its length. Only this task reads stdin.
            let count = unsafe {
                libc::read(libc::STDIN_FILENO, buffer.as_mut_ptr().cast(), buffer.len())
            };
            if count < 0 {
                if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return Err("Cannot read key input.");
            }
            if count == 0 {
                break;
            }
            if data.len() + count as usize > 8194 {
                return Err("API key input exceeds the 8192-byte limit.");
            }
            data.extend_from_slice(&buffer[..count as usize]);
            if !from_stdin && data.contains(&b'\n') {
                break;
            }
        }
        let key = data.strip_suffix(b"\r\n").or_else(|| data.strip_suffix(b"\n")).unwrap_or(&data);
        if key.is_empty() || key.len() > 8192 || !key.iter().all(|b| (0x21..=0x7e).contains(b)) {
            return Err("Supply exactly one nonempty printable ASCII API key, with at most one trailing newline.");
        }
        String::from_utf8(key.to_vec()).map_err(|_| "Invalid API key input.")
    })
    .await
    .map_err(|_| "Cannot read key input.")?
}
