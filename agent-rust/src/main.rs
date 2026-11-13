use exec_agent::{
    Error, Result,
    client::AgentClient,
    core::*,
    providers::credentials::configured_deepseek_provider,
    service::{profile_socket, start_persistent_service},
    terminal::{Transcript, terminal_text},
};
use futures_util::StreamExt;
use std::{
    io::{IsTerminal, Write},
    path::{Path, PathBuf},
    sync::Arc,
};
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    signal::unix::{Signal, SignalKind, signal},
    sync::mpsc,
};
use tokio_util::sync::CancellationToken;
const HELP: &str = "Exec agent CLI (local service client)\n\nUsage: exec-agent [--profile PATH] COMMAND\n  serve [--credentials PATH] [--workspace-tools]\n                                      Run the service in the foreground (DeepSeek)\n  health                              Show service capabilities\n  models                              Discover provider models\n  list                                List saved conversations\n  new MODEL [WORKSPACE] [--manual]     Create a conversation (auto approval by default)\n  show ID                             Show saved/current conversation state\n  delete ID                           Delete an idle conversation permanently\n  configure ID auto|manual PROMPT      Replace idle session policy and system prompt\n  chat ID                             Interactive chat; requires a terminal\n  send ID MESSAGE                     Submit one message and follow its operation\n  watch ID                            Observe until Ctrl-C; never approves automatically\n  cancel ID OPERATION_ID               Cancel exactly that operation\n  approve ID OPERATION_ID APPROVAL_ID  Approve exactly that pending action\n  deny ID OPERATION_ID APPROVAL_ID     Deny exactly that pending action\n\nDefault profile: ~/.exec-agent\nOnly serve starts a service. There are no automatic request retries.\nserve reads DEEPSEEK_API_KEY, otherwise PROFILE/credentials.json (private mode 0600).\n--credentials selects another JSON file; environment credentials take precedence.\nRestart serve after changing credentials. Keys are never accepted as arguments.\nIn chat, /quit or EOF detaches; Ctrl-C cancels an active turn or exits while idle.\nIn send, pending approvals must be resolved explicitly from another client.\n";
fn main() {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("Could not start async runtime");
    let result = runtime.block_on(main_async());
    // Tokio's portable terminal input uses a blocking read. Detaching on Ctrl-C
    // must not wait for another keystroke to unblock that read.
    runtime.shutdown_background();
    if let Err(error) = result {
        eprintln!("{}", terminal_text(&error.to_string()));
        std::process::exit(1);
    }
}
fn unblock_shutdown_signals() -> Result<()> {
    // GUI launchers may pass a blocked signal mask across exec. Register the
    // handlers first, then unblock their signals on this executable's main thread.
    // SAFETY: set points to initialized storage; pthread_sigmask copies it.
    let result = unsafe {
        let mut set = std::mem::zeroed::<libc::sigset_t>();
        libc::sigemptyset(&mut set);
        libc::sigaddset(&mut set, libc::SIGINT);
        libc::sigaddset(&mut set, libc::SIGTERM);
        libc::pthread_sigmask(libc::SIG_UNBLOCK, &set, std::ptr::null_mut())
    };
    if result != 0 {
        return Err(std::io::Error::from_raw_os_error(result).into());
    }
    Ok(())
}
fn absolute(path: impl AsRef<Path>) -> Result<PathBuf> {
    let path = path.as_ref();
    Ok(if path.is_absolute() {
        path.to_owned()
    } else {
        std::env::current_dir()?.join(path)
    })
}
fn write(text: &str) -> Result<()> {
    let mut out = std::io::stdout().lock();
    out.write_all(text.as_bytes())?;
    out.flush()?;
    Ok(())
}
fn print(value: impl serde::Serialize) -> Result<()> {
    write(&format!(
        "{}\n",
        terminal_text(&serde_json::to_string_pretty(&value)?)
    ))
}
async fn main_async() -> Result<()> {
    let mut args: Vec<_> = std::env::args().skip(1).collect();
    let mut profile = std::env::home_dir()
        .ok_or(Error::Invalid("Home directory is unavailable."))?
        .join(".exec-agent");
    if args.first().is_some_and(|s| s == "--profile") {
        if args
            .get(1)
            .is_none_or(|s| s.is_empty() || s.starts_with("--"))
        {
            return Err(Error::Invalid("--profile requires a path."));
        }
        profile = absolute(&args[1])?;
        args.drain(..2);
    }
    if args.is_empty() || matches!(args[0].as_str(), "help" | "--help") {
        return write(HELP);
    }
    let command = args.remove(0);
    if command == "serve" {
        let mut credentials = None;
        let mut tools = false;
        let mut index = 0;
        while index < args.len() {
            match args[index].as_str() {
                "--workspace-tools" if !tools => tools = true,
                "--credentials" if credentials.is_none() => {
                    index += 1;
                    if args
                        .get(index)
                        .is_none_or(|s| s.is_empty() || s.starts_with("--"))
                    {
                        return Err(Error::Invalid("--credentials requires a path."));
                    }
                    credentials = Some(absolute(&args[index])?);
                }
                _ => return Err(Error::Invalid("Invalid serve arguments. Use --help.")),
            }
            index += 1;
        }
        let mut interrupt = signal(SignalKind::interrupt())?;
        let mut terminate = signal(SignalKind::terminate())?;
        unblock_shutdown_signals()?;
        let provider = Arc::new(configured_deepseek_provider(&profile, credentials).await?);
        let service=start_persistent_service(&profile,provider,tools).await.map_err(|_|Error::Invalid("Service startup failed. Check profile permissions, socket, and store lock; stale state is never removed automatically."))?;
        tokio::select! {_=interrupt.recv()=>{},_=terminate.recv()=>{}}
        return service.close().await.map_err(|_| {
            Error::Invalid("Service shutdown failed. Inspect the profile before restarting.")
        });
    }
    let manual = command == "new" && args.last().is_some_and(|s| s == "--manual");
    if manual {
        args.pop();
    }
    let count = match command.as_str() {
        "health" | "models" | "list" => 0..=0,
        "new" => 1..=2,
        "show" | "chat" | "watch" | "delete" => 1..=1,
        "send" | "cancel" => 2..=2,
        "approve" | "deny" | "configure" => 3..=3,
        _ => return Err(Error::Invalid("Invalid command arguments. Use --help.")),
    };
    if !count.contains(&args.len()) {
        return Err(Error::Invalid("Invalid command arguments. Use --help."));
    }
    let client = AgentClient::new(profile_socket(&profile))?;
    match command.as_str() {
        "health" => return print(client.health().await?),
        "models" => return print(client.models().await?),
        "list" => return print(client.list().await?),
        "new" => {
            return print(
                client
                    .create_with_settings(
                        &args[0],
                        &absolute(args.get(1).map(String::as_str).unwrap_or("."))?
                            .to_string_lossy(),
                        SessionSettings {
                            auto_approve: !manual,
                            ..SessionSettings::default()
                        },
                    )
                    .await?,
            );
        }
        "configure" => {
            let auto_approve = match args[1].as_str() {
                "auto" => true,
                "manual" => false,
                _ => return Err(Error::Invalid("Approval mode must be auto or manual.")),
            };
            return print(
                client
                    .update_settings(
                        &args[0],
                        SessionSettings {
                            auto_approve,
                            system_prompt: args[2].clone(),
                        },
                    )
                    .await?,
            );
        }
        "show" => return print(client.get(&args[0]).await?),
        "delete" => {
            client.delete(&args[0]).await?;
            return print(serde_json::json!({"deleted":true}));
        }
        "cancel" => return print(client.cancel(&args[0], &args[1]).await?),
        "approve" | "deny" => {
            return print(
                client
                    .approve(&args[0], &args[1], &args[2], command == "approve")
                    .await?,
            );
        }
        _ => {}
    }
    let interactive = command == "chat";
    if interactive && (!std::io::stdin().is_terminal() || !std::io::stdout().is_terminal()) {
        return Err(Error::Invalid(
            "chat requires an interactive terminal. Use send/watch and explicit approve/deny commands for scripts.",
        ));
    }
    let mut interrupt = signal(SignalKind::interrupt())?;
    unblock_shutdown_signals()?;
    let lifetime = CancellationToken::new();
    let (send, mut input) = mpsc::channel(32);
    if interactive {
        let lifetime = lifetime.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(tokio::io::stdin()).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                if send.send(line).await.is_err() {
                    return;
                }
            }
            lifetime.cancel();
        });
    }
    let mut transcript = Transcript::default();
    let id = &args[0];
    let mut session = Follow {
        client: &client,
        id,
        transcript: &mut transcript,
        interrupt: &mut interrupt,
        input: &mut input,
        lifetime: &lifetime,
        interactive,
    };
    if command == "watch" {
        session.follow(None, true).await?;
        return Ok(());
    }
    if command == "send" {
        // Listen for SIGINT before submission, but wait for its acknowledgement
        // before resolving the exact operation to cancel. Never replay a lost POST.
        let operation = client.submit(id, &args[1]).await?;
        let result = session.follow(Some(&operation), false).await?;
        if result.is_none_or(|o| o.state != OperationState::Completed) {
            return Err(Error::Invalid("Operation did not complete."));
        }
        return Ok(());
    }
    session.follow(None, false).await?;
    loop {
        write("\nYou> ")?;
        let line = tokio::select! {biased;_=lifetime.cancelled()=>break,_=session.interrupt.recv()=>break,line=session.input.recv()=>line};
        let Some(line) = line else {
            break;
        };
        if line.trim() == "/quit" {
            break;
        }
        if line.trim().is_empty() {
            continue;
        }
        let operation = client.submit(id, &line).await?;
        session.follow(Some(&operation), false).await?;
    }
    Ok(())
}
struct Follow<'a> {
    client: &'a AgentClient,
    id: &'a str,
    transcript: &'a mut Transcript,
    interrupt: &'a mut Signal,
    input: &'a mut mpsc::Receiver<String>,
    lifetime: &'a CancellationToken,
    interactive: bool,
}
impl Follow<'_> {
    async fn cancel(&self) -> Result<bool> {
        let snapshot = self.client.get(self.id).await.map_err(|_| {
            Error::Invalid(
                "Cancellation could not be confirmed. Inspect the conversation before continuing.",
            )
        })?;
        if let Some(op) = snapshot.operation
            && op.state.active()
        {
            self.client.cancel(self.id,&op.id).await.map_err(|_|Error::Invalid("Cancellation could not be confirmed. Inspect the conversation before continuing."))?;
            return Ok(true);
        }
        Ok(false)
    }
    async fn follow(
        &mut self,
        operation: Option<&str>,
        continuous: bool,
    ) -> Result<Option<Operation>> {
        let cancel = self.lifetime.child_token();
        let _guard = cancel.clone().drop_guard();
        let mut events = self.client.events(self.id, cancel);
        let mut prompted = std::collections::HashSet::new();
        loop {
            let frame = tokio::select! {biased;
                _=self.lifetime.cancelled()=>return Ok(None),
                _=self.interrupt.recv()=>{if continuous||!self.cancel().await?{return Ok(None);}continue;},
                frame=events.next()=>frame,
            };
            let Some(frame) = frame else {
                return Ok(None);
            };
            let frame = frame?;
            write(&self.transcript.frame(&frame))?;
            let snapshot = match frame {
                ServiceEvent::Snapshot { snapshot }
                | ServiceEvent::Runtime {
                    snapshot: Some(snapshot),
                    ..
                } => snapshot,
                _ => continue,
            };
            if operation.is_some_and(|id| snapshot.operation.as_ref().is_none_or(|op| op.id != id))
            {
                return Err(Error::Invalid(
                    "Another client changed the active operation. Inspect the conversation before continuing.",
                ));
            }
            if !continuous
                && snapshot
                    .operation
                    .as_ref()
                    .is_none_or(|op| !op.state.active())
            {
                return Ok(snapshot.operation);
            }
            if self.interactive
                && let Some(approval) = snapshot.approval
                && prompted.insert(approval.id.clone())
            {
                write("\nApprove this exact action? [y/N] ")?;
                let answer = tokio::select! {biased;_=self.lifetime.cancelled()=>return Ok(None),_=self.interrupt.recv()=>{self.cancel().await?;continue;},answer=self.input.recv()=>answer};
                if let Some(answer) = answer {
                    self.client
                        .approve(
                            self.id,
                            &approval.operation_id,
                            &approval.id,
                            answer.trim().eq_ignore_ascii_case("y"),
                        )
                        .await?;
                }
            }
        }
    }
}
