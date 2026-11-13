# Local service and CLI — API v1

The HTTP API extends the TypeScript sketch with session configuration and deletion. New conversations now default to auto-approval; clients requiring individual approvals must explicitly request manual mode. The service owns the manager, provider, tools, approvals and JSON persistence; clients never run another agent loop. The Swift app is not connected yet.

## Standalone startup and credentials

From `agent-rust/`, run `cargo build --locked --release`, then:

```sh
# Provision DEEPSEEK_API_KEY securely in the environment first, or use private JSON.
./target/release/exec-agent serve
./target/release/exec-agent --profile /absolute/profile serve --credentials /private/credentials.json --workspace-tools
```

Initial credentials are loaded at startup; API-managed JSON credentials can then change live:

1. `DEEPSEEK_API_KEY`, if present, overrides JSON entirely. Empty/invalid values fail closed.
2. `--credentials PATH`, otherwise `PROFILE/credentials.json` (default `~/.exec-agent/credentials.json`).

The file contains `{"deepseek":{"apiKey":"YOUR_DEEPSEEK_API_KEY"}}`, or `{}` when disconnected. An absent file also means disconnected and does not prevent history access. Provision it privately using a secure editor or secret tool; never commit a real key. The loader requires an owned regular file with no group/other permissions (`0600`), refuses final-component symlinks, bounds reads to 16 KiB, and never repairs insecure permissions. API writes use private same-directory staging, file sync, atomic rename and directory sync. This is plaintext storage, not encryption or Keychain. There is no `.env` parser, implicit sign-in, credential CLI argument, or automatic external-file reload.

Keep profiles and credential files **outside all model workspaces**. Approved shells are not sandboxed; same-user code can still read same-user files. Client commands do not load credentials. Environment or external-file changes require restart. API JSON changes take effect without restart. Startup performs no model discovery or inference. SIGINT/SIGTERM take the cancellation/checkpoint/close path; repeated signals do not forcibly abandon tools.

## Embedded startup

`service::start_persistent_service(profile, provider, workspace_tools)` accepts an absolute profile path, `Arc<dyn ChatProvider>`, and an explicit tool opt-in. `providers::credentials::configured_deepseek_provider` provides the same JSON/environment setup; alternatively construct `DeepSeekProvider` with a host-owned async `CredentialSource`.

```rust,ignore
let service = exec_agent::service::start_persistent_service(
    absolute_profile_path, configured_provider, false,
).await?;
// Host owns signal handling/lifetime. Wait for explicit shutdown, then:
service.close().await?;
```

`Service::close` consumes ownership, making duplicate closes impossible in safe Rust. Dropping the handle requests shutdown, but explicit `close().await` is needed to confirm completion. Opening restores records but never resumes inference or actions. Tools apply to new and restored conversations; their execution follows the persisted session policy. New sessions default to auto mode. Manual single-action grants are never restored; restart never resumes an operation, regardless of policy.

```
profile/                    owned private directory, mode 0700
  credentials.json          optional private JSON-backed plaintext credentials, mode 0600
  service.sock              HTTP Unix socket, mode 0600
  conversations/
    .lock/                  exclusive store ownership
    <conversation-id>.json  versioned durable record, mode 0600
```

The full socket path is at most 100 UTF-8 bytes. Existing socket endpoints and insecure/symlinked profile directories are refused, never overwritten or silently made private.

## CLI

Run `./target/release/exec-agent` (or `cargo run --`) with an optional leading `--profile PATH`:

| Command | Behavior |
|---|---|
| `serve [--credentials PATH] [--workspace-tools]` | Foreground DeepSeek service; only this command starts a service |
| `health` | Show service capabilities |
| `models` | Explicit provider model discovery |
| `providers` | Inspect configuration status, never credentials |
| `connect PROVIDER` | Read API key from bounded private piped stdin; never arguments or echoed terminal input |
| `disconnect PROVIDER` | Remove JSON-backed credentials; environment credentials are externally managed |
| `list` | List conversation summaries |
| `new MODEL [WORKSPACE] [--manual]` | Create a conversation; workspace defaults to cwd, auto mode by default |
| `configure ID auto\|manual PROMPT` | Replace idle session policy and system prompt; use `""` for an empty prompt |
| `show ID` | Inspect current/saved state |
| `delete ID` | Permanently delete an idle conversation; cancel and await active work first |
| `chat ID` | Interactive transcript and input; requires a terminal |
| `send ID MESSAGE` | Submit once and follow that operation; nonzero exit on failure/interruption |
| `watch ID` | Observe across turns; never auto-approves |
| `steer ID OPERATION_ID MESSAGE` | Add input at the next safe boundary of this active operation |
| `cancel ID OPERATION_ID` | Request cancellation of exactly that operation |
| `approve ID OPERATION_ID APPROVAL_ID` | Approve exactly that pending action |
| `deny ID OPERATION_ID APPROVAL_ID` | Deny exactly that pending action |

`chat` prints the exact approval description/workspace and accepts only `y` to approve; other answers deny. Terminal control/OSC/bidi characters in model/tool output are escaped. Ctrl-C in chat/send cancels an active turn and waits for settlement, or exits if idle. `/quit` at chat input or EOF detaches. Ctrl-C in watch only detaches. Disconnecting never approves, cancels, or rejects work. Pending approval in `send` must be resolved explicitly from another client.

No client command retries a mutation. A lost response may follow real effects: use show/watch before deciding what to do next. If another client changes the operation before send attaches, it reports the mismatch rather than following the wrong turn.

## HTTP API v1

HTTP/1.1 over the private Unix socket, not TCP. No cookies, CORS or remote authentication. Origin/Fetch-Metadata browser requests are rejected. Same-user processes are trusted. **Never forward this socket through a public/network proxy.**

Bodies require `Content-Type: application/json` and reject unknown fields. Request bodies are bounded to 256 KiB, text to 128 Ki UTF-16 code units, model IDs to 128 code units, and workspace paths to 4,096 code units. Workspaces must be existing absolute directories and are canonicalized. Approval/cancellation IDs are UUIDs. Errors are an HTTP status plus `{"error":"safe message"}`, never raw provider exceptions. Exact diagnostic wording is not a machine-readable error code; oversized/interrupted bodies can also reset the connection.

| Method | Path | Body / response |
|---|---|---|
| GET | `/v1/health` | `{version:1, toolsEnabled:boolean}` |
| GET | `/v1/providers` | Provider status array; no secrets or account identifiers |
| PUT | `/v1/providers/:id` | `{apiKey}` → provider statuses after private JSON save |
| DELETE | `/v1/providers/:id` | Disconnect JSON-backed provider → statuses |
| GET | `/v1/library` | Shared defaults and ordering |
| PUT | `/v1/library` | `{defaultModel,settings,order}` → saved configuration |
| GET | `/v1/models` | Neutral model array: `id`, `name`, optional `contextWindow`, `maxOutputTokens` |
| GET | `/v1/conversations` | Summary array, omitting `messages` and `approval` |
| POST | `/v1/conversations` | `{model,workspace,settings?}` → `201 ConversationSnapshot`, after durable creation |
| PUT | `/v1/conversations/:id/settings` | `{systemPrompt,autoApprove}` → `200 ConversationSnapshot`, after durable idle-only replacement |
| GET | `/v1/conversations/:id` | `ConversationSnapshot` |
| PUT | `/v1/conversations/:id/title` | `{title}` → saved idle snapshot |
| PUT | `/v1/conversations/:id/model` | `{model}` → saved idle snapshot |
| POST | `/v1/conversations/:id/fork` | `{}` → `201` independent saved copy; source must be idle without pending input |
| DELETE | `/v1/conversations/:id` | No body → `200 {deleted:true}` after durable deletion; active work returns 409 |
| GET | `/v1/conversations/:id/events` | Live NDJSON |
| POST | `/v1/conversations/:id/turns` | `{text}` → `202 {operationID}` |
| POST | `/v1/conversations/:id/steer` | `{operationID,text}` → `202 {operationID,messageID}` |
| POST | `/v1/conversations/:id/cancel` | `{operationID}` → `202 {accepted:true,operationID}` |
| POST | `/v1/conversations/:id/approvals` | `{operationID,approvalID,approved:boolean}` → `{resolved:true}` |

Missing conversations return 404; invalid requests 400; busy/storage-blocked submissions and stale approvals/cancellations 409. Approval decisions are single use, including races. Cancellation acceptance is not cleanup completion; the acknowledgement echoes the exact operation accepted for cancellation.

A snapshot has `id`, `model`, `workspace`, `configuration`, `messages`, `pendingInput`, `operation`, `approval`, `activeToolCallID`, and `storageError`. Nullable fields are serialized explicitly as null. Operation states are `running`, `awaiting_approval`, `cancelling`, `completed`, `failed`, `interrupted`. Messages retain the original user/assistant/tool tagged JSON shapes, assistant completion status, finalized calls and paired tool outcomes. Rust declarations are in `src/core/types.rs`; command validation is in `src/service.rs`.

**Turn acceptance is in-memory, not a durable receipt.** A 202 can precede the input checkpoint; a lost response can happen after effects. No idempotent replay mechanism is advertised. Terminal success is published only after its final checkpoint succeeds. Intermediate snapshots/events are not durability receipts.

## Settings and instructions

Optional creation `settings` is `{systemPrompt:string,autoApprove:boolean}`; when omitted,
its default is `{systemPrompt:"",autoApprove:true}`. Both fields are required when supplying
settings. Settings replacement is idle-only (409 while working/updating); no live approval
is implicitly resolved by a configuration request. Failed writes block further work.

Snapshots include `configuration: {settings, instructionsFrozen, workspaceInstructions}`.
The nullable workspace instructions are loaded by the manager from root AGENTS.md at the
first accepted turn, not at session creation. Missing AGENTS.md is frozen as null. Invalid,
linked, nonregular, oversized or non-UTF-8 files reject the turn before acceptance. Each
instruction source is limited to 64 KiB and cannot contain NUL bytes. Instructions are saved
before inference, reused across turns/restart, and never inserted as user transcript rows.
The system prompt can be changed while idle; the project's frozen snapshot is not reloaded.

Settings mutations publish full snapshot frames after settlement, including storage-error
snapshots on failed acknowledgements. A disconnected caller does not abort a settings write.
The API remains local; prompts/project instructions are exposed only to trusted local
clients and the selected provider. Auto mode does not sandbox tools or enable any future
desktop capture capability/OS permission.

## Approval without a connected client

In manual mode, an action remains `awaiting_approval` until an explicit matching approval/denial or cancellation. There is no automatic expiry or requirement for a client to stay connected. Reconnecting obtains the same pending approval. Service shutdown interrupts pending work; restart clears approvals and never grants or replays them.

## Streaming contract

`Content-Type: application/x-ndjson`. Each UTF-8 line is a JSON object, **not SSE**:

1. Initial frame: `{type:"snapshot", snapshot:ConversationSnapshot}`.
2. Later frames: `{type:"runtime", event:RuntimeEvent, snapshot?:ConversationSnapshot}`. Settings settlement may also emit `{type:"snapshot", snapshot:ConversationSnapshot}` without an operation ID.
3. Text events have `type:"text"`, `messageID`, `delta`. Append only the delta.
4. Every non-text event carries a complete snapshot. Replace/reconcile, not append the transcript again.

Runtime events always contain `conversationID` and `operationID`:

| Type | Additional fields |
|---|---|
| `operation` | `state` |
| `message` | `messageID` |
| `text` | `messageID`, `delta` |
| `approval` | `approvalID` (null when withdrawn/resolved) |
| `tool_started` | `callID` |
| `tool_finished` | `callID`, `messageID`, `outcome` |

`activeToolCallID` identifies live executor ownership, including cancellation cleanup. It is null while preparing, awaiting approval, saving intent, and after settlement. Resolve a non-null ID against finalized assistant calls. Null does not imply the whole operation is idle. This field is never restored from durable intent.

`tool_started` means the executor was entered after approval and successful intent checkpoint, not that effects succeeded. Every finalized call receives one `tool_finished` result event, including denial, preparation failure, interruption, and non-execution. Outcomes are `completed`, `denied`, `failed`, `interrupted`, `not_executed`. Calls that never enter their executor have no start event. Message events still accompany tool results; reconcile by message ID. Abrupt exit can prevent delivery; reconnect/recovery uses snapshots, not replay.

Tool events are not durable acknowledgments. A result may precede its checkpoint. A completed tool result remains completed if cancellation arrives after publication; cancellation at the executor/result handoff is conservatively interrupted with possible effects.

Subscription and initial snapshot have no update gap. There is no replay cursor, heartbeat or automatic reconnection. Streams stay open after terminal operations to observe later turns. Slow observers are disconnected rather than blocking inference: queues are bounded to 1 MiB (one larger snapshot is permitted). Clients bound responses/frames to 32 MiB. Reconnect explicitly after interruption; never resubmit automatically.

```sh
curl --unix-socket "$HOME/.exec-agent/service.sock" http://localhost/v1/health
curl --no-buffer --unix-socket "$HOME/.exec-agent/service.sock" \
  http://localhost/v1/conversations/CONVERSATION_ID/events
```

## Shutdown and recovery

`service.close().await` stops accepting connections, disconnects observers/partial requests, settles catalog mutations, cancels runs, awaits cooperative provider/tool cleanup and final checkpoints, then closes the manager/store. Noncooperative adapters can delay shutdown. Normal shutdown removes the socket and lock. Forced termination is not a clean tool shutdown.

Crash recovery never resumes work or steals ownership. Verify the old host and its tool processes have stopped, then explicitly remove only the stale socket and `conversations/.lock` for that profile. See [README.md](README.md#persistence-and-recovery) for interrupted intent, missing results and possible side effects.

Tests cover these contracts with fake providers and real sockets/subprocesses. Live DeepSeek, interactive TTY operation, Linux deployment and Swift UI integration are not claimed verified.

## Steering

Steering targets an exact active operation; stale, cancelling or settling operations
return 409. Ordinary turn submission still rejects a busy conversation. Accepted steering
input is observable in `pendingInput` (up to 32 messages), checkpointed by the runner while
streaming or executing, and incorporated only after all finalized calls have outcomes.
The `input` event contains `messageID`; later message events reconcile the same ID when
incorporated. A pending approval is withdrawn; old unstarted calls receive `not_executed`.
A live executor keeps ownership through completion/cleanup and is not cancelled merely
because new input arrived. No later old action starts after the safe boundary.

Like turn submission, 202 is in-memory acceptance, not a durable receipt. A crash before
its checkpoint can lose newly accepted input. Checkpointed pending input survives restart
but never starts inference itself; the next explicit turn incorporates it before new input.
Cancellation or step-limit failure can retain pending input for that next explicit turn.
Version-3 checkpoints retain pending input; older versions are read conservatively.

## Session library

`metadata` contains `title` (nullable before first input), `manuallyNamed` and `activityAt`
(Unix milliseconds). The first prompt supplies a fallback title; manual names are retained.
Rename/model changes are idle-only and checkpointed before publication. Forks preserve
transcript IDs and frozen instructions in an independent conversation; they never resume
work or mutate the source. Resource references will be managed when assets/logs are added.

`GET/PUT /v1/library` owns shared `defaultModel` (nullable), new-session `settings`, and
`order` (up to 10,000 unique conversation UUIDs). Omitted creation model/settings use these
defaults; workspace remains explicit. Order IDs missing from the catalog are harmless and
ignored. Unlisted sessions follow in stable ID order. `library.json` is atomically saved in
the private conversation store. Failed library writes block library mutations/default-based
creation until reload; existing conversation execution is independent. Corrupt library data
fails startup rather than silently resetting preferences. Clients retain their own selected
session, drafts, windows and scroll state.

CLI commands: `library`, `library-set JSON`, `rename ID TITLE`, `model ID MODEL`, `fork ID`.

## Credential lifecycle

Missing credentials do not prevent startup, browsing, renaming, forking or deleting saved
conversations. Inference/discovery fail safely before transport without a configured key.
DeepSeek API-key onboarding is an explicit local credential write, not a live validation
request. `connected` means a credential is configured, not that the service verified it.
Statuses contain `id`, `name`, `connected`, `source` (`json` or `environment`), `manageable`
and `blocked`. Environment credentials override JSON and cannot be changed through the API.

The manager rejects account mutations while any conversation/catalog mutation is active
(409), and excludes new manager submissions/creation during a credential mutation. Writes
remain owned after client disconnect. Failed write acknowledgements block that credential
source until reload; no retry or permission repair is performed. Requests containing keys
must never be logged. Keys never appear in snapshots, events, provider statuses or errors.

## Unreadable conversations

Conversation summaries include `{id,unreadable:true,title:"Unreadable conversation"}` for
corrupt, unsupported or oversized owned regular records. They are never loaded as runnable
context or overwritten. GET/turn/configuration requests for those IDs return 409. Explicit
DELETE removes the retained file durably. Valid conversations remain usable. Symlinks,
special files, unknown JSON filenames, changing file identities or lost/foreign ownership
remain whole-store integrity failures. Library metadata corruption also fails startup.

## Provider services

`POST /v1/search` accepts `{model,query}` and returns `{query,answer,sources:[{title,url}]}`.
The standalone DeepSeek service also registers `web_search` as a runner tool, independently
of workspace file/shell opt-in. Queries are public single-line text (DeepSeek: at most 128
characters); results contain up to ten unique credential-free HTTPS source URLs and bounded
excerpts. Sources and excerpts remain untrusted evidence. This is not URL fetching and
executes no JavaScript. Search consumes provider service access and is never retried.

`GET /v1/providers/deepseek/balance` returns `{amount,currency}` arrays, keeping exact decimal
amounts as strings rather than floating point. These services use bounded JSON bodies,
provider deadlines and explicit cancellation. Read-only results started before a credential
change are rejected instead of being presented under the new account. They do not mutate
conversation context unless invoked as a runner tool. `toolsEnabled` in health describes
non-search tools; standalone search can be available while it is false.

CLI: `search MODEL QUERY`, `balance PROVIDER`. Live provider compatibility is unverified;
tests use synthetic credentials and fake transports, not the live service.

## Public content fetching

`POST /v1/fetch` accepts `{url}` and returns `{url,contentType,text,truncated}`. The same
operation is registered as `fetch_content` in the standalone runner and exposed as `fetch URL`
in the CLI. No provider credentials, website credentials, cookies or ambient proxies are
used. Public HTTPS port 443 only; all resolved addresses must be public, and the HTTP client
is pinned to those addresses while retaining ordinary TLS hostname/certificate validation.
The connected peer must match a validated address. This improves on Swift's DNS preflight,
which resolved the hostname again at connection time.

At most three redirects are followed with fresh URL/DNS validation. Ordinary HTTP redirects
are upgraded to HTTPS before requesting them; nonstandard ports and credential-bearing URLs
are rejected. There is a 30-second overall deadline, 1 MiB download bound, and 24,000-byte
UTF-8 output bound. HTML is parsed by scraper/html5ever; script/style/template/head content
is excluded. Plain text, JSON, XML and HTML are supported when UTF-8; invalid encodings,
binary/PDF content, oversized bodies and empty extracted content fail explicitly. No
JavaScript execution, browser sessions, login or automatic retries. Returned text is
untrusted evidence, never a generated summary. Tests use fake DNS/transports; no live
website compatibility or hostile-network sandbox guarantee is claimed.
