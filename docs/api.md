# Agent HTTP service — API v1

The HTTP API owns session configuration and deletion. New conversations default to auto-approval; clients requiring individual approvals must explicitly request manual mode. The service owns the manager, provider, tools, approvals and JSON persistence; clients never run another agent loop. The Swift app launches the bundled backend and consumes this API.

## Standalone startup and credentials

From `backend/`, run `cargo build --locked --release`, then:

```sh
# Provision a transport token once (or inject it through your service manager).
export EXEC_AGENT_TOKEN="$(openssl rand -hex 32)"
# Separately provision provider credentials through the API or private JSON.
./target/release/exec-agent
./target/release/exec-agent --profile /absolute/profile --credentials /private/credentials.json --workspace-tools
```

Initial credentials are loaded at startup; API-managed JSON credentials can then change live:

1. `DEEPSEEK_API_KEY`, if present, overrides its DeepSeek JSON entry. Empty/invalid values fail closed.
2. `--credentials PATH`, otherwise `PROFILE/credentials.json` (default `~/.exec-agent/credentials.json`).

The file can contain `{"deepseek":{"apiKey":"YOUR_DEEPSEEK_API_KEY"},"openai":{...}}`, or `{}` when disconnected. The OpenAI entry is provider-owned; see browser authentication below. Both adapters serialize document updates and preserve the other provider’s fields. An absent file also means disconnected and does not prevent history access. Provision it privately using a secure editor or secret tool; never commit a real key. The loader requires an owned regular file with no group/other permissions (`0600`), refuses final-component symlinks, bounds the shared document to 1 MiB, and never repairs insecure permissions. API writes use private same-directory staging, file sync, atomic rename and directory sync. This is plaintext storage, not encryption or Keychain. There is no `.env` parser, implicit sign-in, credential CLI argument, or automatic external-file reload.

Keep profiles and credential files **outside all model workspaces**. Approved shells are not sandboxed; same-user code can still read same-user files. Environment or external-file changes require restart. API JSON changes take effect without restart. Startup performs no model discovery or inference. SIGINT/SIGTERM take the cancellation/checkpoint/close path; repeated signals do not forcibly abandon tools.

## Token files, containers and local administration

`exec-agent-admin` administers the local service at `127.0.0.1` using
`EXEC_AGENT_PORT` (default `8765`). It uses the **same token resolver** as the server:

- Set either `EXEC_AGENT_TOKEN` (64 hex characters) or `EXEC_AGENT_TOKEN_FILE`
  (an absolute path), never both. Even an empty explicit setting is an error; it
  does not unset that source or enable fallback.
- `EXEC_AGENT_DEFAULT_TOKEN_FILE` supplies a fallback **location**, used only when
  neither explicit source is set. Invalid explicit values never fall back.
- `exec-agent-admin init-token` validates the selected token or creates a missing
  selected file privately, once, without output. It never repairs permissions or
  rotates existing credentials. The file must be owned, regular, private (`0600`),
  and not a final-component symlink; creation requires an owned private parent.
  Server startup, health and other admin commands only read provisioned tokens.

The Docker image sets `EXEC_AGENT_DEFAULT_TOKEN_FILE=/var/lib/exec/profile/admin-token`,
not an explicit file source. Its entrypoint runs `init-token`, then the server with
workspace tools enabled. Both `docker exec` administration and health checks resolve
credentials independently using that same image/container environment—not a PID 1
shell workaround. A valid injected `EXEC_AGENT_TOKEN` takes precedence without
reading or changing the default file. To select a different file, set
`EXEC_AGENT_TOKEN_FILE` and leave `EXEC_AGENT_TOKEN` unset (not empty).

From the repository root, the supplied `compose.yaml` persists the private profile
and workspaces in separate volumes and exposes only the relay's TLS reverse proxy.
Relay registration is open to any backend when `EXEC_RELAY_ALLOWED_ROUTES` is unset,
empty or whitespace-only; host-token validation, device pairing and encryption
remain required. For this default mode, set `EXEC_RELAY_DOMAIN` and run
`docker compose up -d --build`, then configure remote access using the admin commands
below. A nonempty allowlist restricts registration to its route hashes.

To configure a restricted relay before any backend can register, bootstrap the
private agent first, bypassing the agent → proxy → relay startup dependencies:

```sh
export EXEC_RELAY_DOMAIN="relay.example.com" # Your public relay DNS hostname.
docker compose up -d --build --no-deps --wait agent
docker compose exec -T agent exec-agent-admin health
docker compose exec -T agent exec-agent-admin providers list
docker compose exec -T agent exec-agent-admin remote configure --relay "wss://$EXEC_RELAY_DOMAIN"
# In a private interactive terminal, with stdin/stdout attached (no -T or pipe):
docker compose exec agent exec-agent-admin remote invite
```

`remote configure` enables access by default; there is no `--enable` flag. Configure
it **before** inviting. No running relay is needed to issue an invitation; the
connection may report `connecting` / `relayNotFound` until the relay is available.
From the invitation displayed locally, copy **only `route`**, the 64-character
lowercase SHA-256 hash of the host registration token. Do not pipe `remote invite`
to `jq`, redirect it, or run it in recorded terminals/CI: its JSON includes the
single-use invitation secret, and the CLI deliberately requires interactive
stdin/stdout. Never print/copy `remote.json` or the private host registration token.

```sh
export EXEC_RELAY_ALLOWED_ROUTES="<64-character lowercase route hash>"
# Daemon-free validation; only the public hostname and route hashes are rendered.
docker compose config --quiet
docker compose up -d --build relay proxy
docker compose exec -T agent exec-agent-admin remote status
# When ready to pair, generate a fresh invitation if the first expired (five minutes):
docker compose exec agent exec-agent-admin remote invite
```

For multiple agents, use comma-separated route hashes (at most 64). Malformed
nonempty lists fail startup; clearing the entire list reopens registration. Persist
the hostname and optional route allowlist in deployment configuration, **never**
the host token or invitation secret in Compose environment, files, logs or command
arguments.
After changing the allowlist, use `docker compose up -d --force-recreate relay`;
`docker compose restart` alone does not replace container environment. The agent
reconnects its transport without replaying API commands. Public DNS/TLS and the
container deployment still need verification on the target host. See
[relay admission](../relay/README.md#production-host-admission).

Keep transport/provider secrets out of command arguments and source control.
The local admin CLI does not run chat, inference or model-discovery commands.
Run `exec-agent-admin --help` for provider and remote administration commands.

### Device login interruption and uncertain commands

`exec-agent-admin providers connect openai --device-code` requires interactive
terminal stdin/stdout. It launches no browser and prints challenge material only
on that terminal. Ctrl-C/SIGTERM/SIGHUP requests cancellation of the **same attempt
ID once**; additional signals do not resend or abandon cleanup. A cancellation
acknowledgement is not settlement. The CLI observes for up to five seconds after
that request finishes, even if the cancellation POST failed or lost its response.

Only an observed terminal state for that attempt can establish settlement.
Completion can win the cancellation race: the CLI then reports `state:completed`
and `connected:true`, not interruption. Observed failed/interrupted states are
reported as such. `providers cancel-login ATTEMPT_ID` also includes the observed
terminal `state` in its JSON; `cancellationRequested:true` means the one request
was attempted, **not** that it was accepted or prevented credential persistence.
Cancellation POST errors are reported even if observation subsequently settles.

A lost/invalid login acknowledgement, observation error, changed/missing attempt,
or settlement timeout reports an **unknown outcome** and fails the command.
The attempt may still be active, or credentials may already have been saved.
Before starting another login, run:

```sh
exec-agent-admin providers login-status
exec-agent-admin providers status
```

If cancellation is still needed, use only the exact active ID from `login-status`;
do not blindly replay login or cancellation. HTTP/validation/output failures in
other mutating commands can likewise occur after effects: inspect provider or
remote status before deciding what to do next. The CLI does not retry mutations,
provider authentication or inference.

## Embedded startup

`service::start_persistent_service(profile, provider, workspace_tools, address, access)` accepts an absolute profile path, `Arc<dyn ChatProvider>`, an explicit tool opt-in, a `SocketAddr`, and an explicit `HttpAccess` policy. The execution runtime itself does not depend on HTTP authentication. `providers::credentials::configured_deepseek_provider` provides the same JSON/environment setup; alternatively construct `DeepSeekProvider` with a host-owned async `CredentialSource`.

```rust,ignore
let service = exec_agent::service::start_persistent_service(
    absolute_profile_path, configured_provider, false, "127.0.0.1:8765".parse()?,
    exec_agent::service::HttpAccess::bearer(&api_token, None)?,
).await?;
// Host owns signal handling/lifetime. Wait for explicit shutdown, then:
service.close().await?;
```

`Service::close` consumes ownership, making duplicate closes impossible in safe Rust. Dropping the handle requests shutdown, but explicit `close().await` is needed to confirm completion. Opening restores records but never resumes inference or actions. Tools apply to new and restored conversations; their execution follows the persisted session policy. New sessions default to auto mode. Manual single-action grants are never restored; restart never resumes an operation, regardless of policy.

```
profile/                    owned private directory, mode 0700
  credentials.json          optional private JSON-backed plaintext credentials, mode 0600
  metadata.json             optional account-scoped model/usage/balance cache, mode 0600
  images/                   immutable UUID.image PNG/JPEG assets, mode 0700/0600
  shell-logs/               retained shell output, mode 0700/0600
  conversations/
    .lock/                  exclusive store ownership
    <conversation-id>.json  versioned durable record, mode 0600
    <conversation-id>/     session-owned diagnostics directory, mode 0700
      diagnostics.jsonl    current diagnostic JSONL, mode 0600, at most 1 MiB
      diagnostics.previous.jsonl  optional previous diagnostic JSONL, same limit/mode
```

Transcripts remain flat `<conversation-id>.json` files; there is no transcript migration.
Diagnostic records contain only timestamps, UUID conversation/operation/message IDs,
allowlisted lifecycle events and typed failure categories/statuses—not prompts, responses,
tool arguments, raw errors, credentials or account details. Appends are best-effort,
serialized with session saves/deletion, and retained across restart. Before an append
would exceed 1 MiB, the current log replaces the previous log; at most two diagnostic
files are retained per session. These logs are troubleshooting aids, not a complete audit
trail or durable operation receipts. Writes require an existing session record and never
recreate deleted sessions. Session deletion removes both diagnostic files and their
folder before removing the transcript, including for unreadable transcripts and old
sessions without a diagnostic folder. Unsafe targets or unexpected folder contents
are refused rather than followed or recursively removed.

Insecure/symlinked profile directories are refused, never silently made private.

## Backend launcher

The `exec-agent` executable only hosts the backend; use the separate local-only
`exec-agent-admin` for administration, not chat/list/watch. Server options are `--profile PATH`, `--credentials PATH`,
`--workspace-tools`, `--host IP`, `--port PORT`, and the deliberate `--insecure-no-auth` opt-out.
The default profile is `~/.exec-agent`, and the default bind is **`127.0.0.1:8765`**.
`EXEC_AGENT_HOST` and `EXEC_AGENT_PORT` also configure binding; explicit flags take precedence.
Hosts must be numeric IP addresses. Loopback IPv4/IPv6, a specific interface, or a wildcard
are supported. Network exposure requires an explicit bind; IPv6 wildcard behavior is OS-dependent.
Invalid configuration fails startup, never falls back or selects another server.

The bundled macOS app always launches its helper at `127.0.0.1:8765` with fresh,
separate API/native credentials. It ignores standalone endpoint and token overrides,
strips inherited provider credential overrides, and cannot attach to an external service.
An occupied port fails startup rather than selecting another listener. See
[architecture.md](architecture.md) for frontend ownership and capability boundaries.

After binding and initialization, the standalone child writes only `ready\n`; this
authenticates neither a server nor a caller, and clients still must authenticate.
There is no port scanning, endpoint discovery, or fallback server. SIGINT/SIGTERM
cancel and await work, checkpoint, release the listener and close the store.

## HTTP API v1: authentication and deployment

One HTTP/1.1 TCP server dispatches directly to the existing manager/runtime. There is no
Unix-socket alternative, proxy API or second runner. The local admin CLI uses this API.

- **Default authentication:** provision 32 cryptographically random bytes encoded as
  **64 hex characters** through `EXEC_AGENT_TOKEN` or a private token file (see above).
  Standalone startup without a valid token fails closed.
  Send `Authorization: Bearer <token>` on **every** request, including health, reads and NDJSON
  subscriptions. Missing/wrong/ambiguous credentials return 401 with `WWW-Authenticate: Bearer`,
  before parsing bodies or calling the manager. Authentication failures close the connection.
- **Scope:** this is one shared **administrator** credential, not individual user accounts,
  tenant isolation, per-client scopes or provider credentials. Every holder can read/control
  conversations, manage provider settings and enable/use host tools. Generate once, provision
  through a trusted channel, keep it out of URLs/source/logs, and restart the service and update
  clients to rotate it. Restart closes old streams; work is not replayed.
- **Encryption:** the backend serves HTTP, not TLS. For non-loopback use, protect traffic with
  HTTPS termination or an encrypted tunnel/VPN. Restrict direct access to the backend listener;
  a normal LAN is not automatically trusted. Provider credentials, tokens and conversation
  data otherwise travel in plaintext. The current Swift app connects only to its bundled
  loopback helper; other frontends must provide their own protected remote transport.
- **Externally enforced access:** `--insecure-no-auth` explicitly disables the API token check
  for a protected proxy/VPN deployment. It cannot be combined with `EXEC_AGENT_TOKEN`. Bind
  behind that boundary and firewall the direct port so callers cannot bypass it. This flag
  never enables native screen capabilities. There is no implicit unauthenticated mode.
- **Browser clients:** no cookies or CORS. Requests with Origin/Fetch-Metadata headers are
  rejected even when authenticated. A browser frontend requires a separate deliberate origin
  and credential design; never embed the administrator token in publicly served JavaScript.
- **Proxy configuration:** preserve Authorization, avoid logging credentials/bodies, disable
  upstream retries for commands, and disable buffering for `/events` NDJSON responses. Keep
  observer connections open while idle. A proxy is deployment infrastructure, not a second API.

```sh
# Authenticated local server (do not regenerate this token for each client):
export EXEC_AGENT_TOKEN="$(openssl rand -hex 32)"
./target/release/exec-agent --profile /absolute/private/profile --workspace-tools

# Authenticate without putting the expanded token in curl's command-line arguments:
curl --config - <<EOF
url = "http://127.0.0.1:8765/v1/health"
header = "Authorization: Bearer $EXEC_AGENT_TOKEN"
EOF

# Explicit network bind; supply TLS/tunnel protection and restrict access separately:
./target/release/exec-agent --host 0.0.0.0 --port 8765
```

Tools and workspace paths belong to the **backend host**, not the connecting client.
OpenAI browser auth still uses a callback on the backend's loopback port 1455; authenticate
on that host or explicitly tunnel that callback to the browser machine. Changing the API
transport does not turn provider OAuth into a remote callback service. Native capture belongs
to an explicitly authorized frontend's machine, not automatically the backend host.

Bodies require `Content-Type: application/json` and reject unknown fields. Request bodies are bounded to 12 MiB (for encoded images), text to 128 Ki UTF-16 code units with an additional 128 KiB UTF-8 turn bound, model IDs to 128 code units, and workspace paths to 4,096 code units. Workspaces must be existing absolute directories and are canonicalized. Approval/cancellation IDs are UUIDs. Errors are an HTTP status plus `{"error":"safe message"}`, never raw provider exceptions. Exact diagnostic wording is not a machine-readable error code; oversized/interrupted bodies can also reset the connection.

Proven pre-effect service gates (authorization/allowlist, admission, routing and request-body/field validation) may add `"delivery":"rejected"` to that same error object. This optional field proves only that **this request** had no effects; it does not imply an earlier request settled. Runtime errors omit it, even when their status is 400, 409 or 503: cancellation or durable/provider work may already have happened. In particular, 500 and storage-recovery 409 responses are not definite rejection evidence. Missing, malformed, unknown or legacy delivery metadata is an **uncertain outcome**, not permission to resubmit. Safe diagnostic messages remain actionable but must not be parsed for delivery evidence.

Model discovery, balance and usage reads return 503 when the manager is closed, including when it closes while a provider read is pending. Account mutation conflicts remain distinct from closure.

The server bounds TCP connections to 64 and separately admits at most 64 non-GET command handlers across HTTP and remote transport, including body reads. Excess commands return 503 before body parsing or effects; there is no admission wait queue. A tracked handler owns its admission permit until it finishes, even after the caller disconnects. Incomplete body reads are cancelled on disconnect/shutdown, but accepted mutations are never aborted to free capacity. GET reads remain outside the command budget. Shutdown waits for accepted writes; stalled storage can therefore delay shutdown indefinitely. A lost response is not permission to retry a mutation automatically.

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
| POST | `/v1/conversations` | `{model,workspace,settings?,disabledTools?:[string]}` → `201 ConversationSnapshot`, after durable creation |
| PATCH | `/v1/conversations/:id` | `{disabledTools:[string]}` → `200 ConversationSnapshot`, after durable idle-only replacement |
| PUT | `/v1/conversations/:id/settings` | `{systemPrompt,autoApprove}` → `200 ConversationSnapshot`, after durable idle-only replacement |
| GET | `/v1/conversations/:id` | `ConversationSnapshot` |
| PUT | `/v1/conversations/:id/title` | `{title}` → saved idle snapshot |
| PUT | `/v1/conversations/:id/model` | `{model}` → saved idle snapshot |
| PUT | `/v1/conversations/:id/workspace` | `{workspace}` → saved idle snapshot, only before the first accepted turn; otherwise 409 |
| POST | `/v1/conversations/:id/clear` | `{}` → `200 ConversationSnapshot`, after cancellation, settlement and durable context/transcript reset in the same session |
| POST | `/v1/conversations/:id/fork` | `{}` → `201` independent saved snapshot of the transcript, including during an active turn |
| DELETE | `/v1/conversations/:id` | No body → `200 {deleted:true}` after cancelling and settling active work, then durably deleting the session and descendants; conflicting mutations return 409 |
| GET | `/v1/conversations/:id/events` | Live NDJSON |
| POST | `/v1/conversations/:id/turns` | `{text,images?,files?:[assetID]}` → `202 {operationID}` |
| POST | `/v1/conversations/:id/steer` | `{operationID,text,images?,files?:[assetID]}` → `202 {operationID,messageID}` |
| POST | `/v1/conversations/:id/cancel` | `{operationID}` → `202 {accepted:true,operationID}` |
| POST | `/v1/conversations/:id/approvals` | `{operationID,approvalID,approved:boolean}` → `{resolved:true}` |

Images may be uploaded while a turn is active, then queued through `/steer` as conversation-owned image references. Steering accepts text, images, or both, with the same eight-image/16 MiB limits as a new turn. Input is incorporated at the next safe runner boundary, not retroactively added to an in-flight provider request. The operation ID remains fixed across uploads: if that operation finishes or is cancelled, a rejected steering request must not be retried as a new turn. Accepted pending images survive cancellation/restart without automatically resuming inference.

Image uploads are fully decoded and validated (PNG/JPEG, nonempty, at most 8 MiB, bounded dimensions/allocation) before reserving or checkpointing a resource. Invalid data or names return 400 without changing the conversation or creating assets. Image preparation admits at most two validation workers and returns 409 instead of queueing excess work. File upload names, size and complete references are also validated before ownership is checkpointed. Once a prepared upload crosses the write boundary, a storage failure returns 500 and retains its reserved reference: a failed response does not prove that publication did not occur. Inspect state rather than automatically resubmitting the upload.

Missing conversations return 404; catalog reservations (including pending deletion), busy/storage-blocked submissions and stale approvals/cancellations return 409, not 404. Read-only snapshots, sync and events remain available during reservations until actual removal. A closed/stopping service returns 503; unexpected internal/storage failures return 500 unless a route explicitly reports a storage-recovery conflict. Invalid requests return 400. Approval decisions are single use, including races. Cancellation acceptance is not cleanup completion; the acknowledgement echoes the exact operation accepted for cancellation.

A snapshot has `id`, `model`, `workspace`, `canChangeWorkspace`, `configuration`, `messages`, `pendingInput`, `metadata`, `usage`, `contextUsage`, `resources`, `operation`, `approval`, `activeToolCallID`, optional `activeToolName`, and `storageError`. Nullable fields are serialized explicitly as null, except `activeToolName`, which is omitted when no tool is executing. Operation states are `running`, `awaiting_approval`, `cancelling`, `completed`, `failed`, `interrupted`. Messages retain the original user/assistant/tool tagged JSON shapes, assistant completion status, finalized calls and paired tool outcomes. Rust declarations are in [`backend/src/core/types.rs`](../backend/src/core/types.rs); command validation is in [`backend/src/service.rs`](../backend/src/service.rs).

`GET /v1/models` may partially refresh provider metadata before another provider stalls or fails. Discovery invalidates the catalog and all conversation revisions on completion, failure, disconnect or its 120-second timeout, including conversations created during discovery. Clients must re-read provider-derived snapshots after that invalidation; a failed discovery response does not imply the caches were unchanged. Discovery is not automatically retried.

**Turn acceptance is in-memory, not a durable receipt.** A 202 can precede the input checkpoint; a lost response can happen after effects. No idempotent replay mechanism is advertised. Terminal success is published only after its final checkpoint succeeds. Intermediate snapshots/events are not durability receipts.

## Clear and fork

`POST /v1/conversations/:id/clear` requires the JSON body `{}` and returns
`200 ConversationSnapshot` only after the cleared record is saved. It keeps the same
session ID; it does not submit `/clear` as a turn, call a provider, replay input/tools,
create a session, or delete child sessions. The encrypted remote route also permits it.

The returned snapshot has `messages:[]`, `pendingInput:[]`, `resources:[]`, and null
`operation`, `approval`, `activeToolCallID`, `usage`, `contextUsage`, and `storageError`.
Opaque provider continuation state and persisted tool-execution state are cleared too.
`model`, `workspace`, the entire `configuration` (system prompt, reasoning effort, search
model, auto approval, and frozen project instructions), and metadata (title, manual naming,
parent provenance, and disabled tools) are preserved; `metadata.activityAt` is refreshed.
Frozen instructions stay frozen even with an empty transcript: clearing a used session
never unlocks its workspace or reloads AGENTS.md. An unused, unfrozen session can still
change workspace, as reported by advisory `canChangeWorkspace`.

Clear immediately cancels active work in the session and its descendants, then waits for
runners and tool cleanup to settle before saving the empty context. Descendants retain
their own transcripts; they are reserved through the reset so no new child work can cross
its durable publication. A child still owned by an active parent delegation cannot be
cleared directly, even if that child has finished its own operation; clear its parent instead.
An upload/settings/catalog mutation underway also conflicts. These conflicts return
`409 {"error":"Conversation is busy."}` without cancelling work or changing context.
Missing sessions return 404; invalid bodies/IDs return 400. A storage-blocked session or
failed clear save returns `409 {"error":"Conversation requires storage recovery."}`; the
previous (possibly now interrupted) transcript remains published with `storageError` set,
and subsequent work/writes are blocked. Accepted cancellation, settlement and the clear
save finish if the caller disconnects; do not automatically retry an uncertain command.

Clear removes usable resource references from the snapshot, but retains a private, durable
cleanup ledger in the session record. It does **not** immediately remove attachment,
image, shell-log, or workspace files. Deleting the session later cleans up ledger assets
only when no surviving session/fork owns them; unreadable records defer cleanup. A fork
made after clear does not inherit that hidden cleanup ledger.
Observers receive a full `snapshot` frame after settlement. `/sync` with an old `after`
anchor returns `reset:true`, `offset:0`, `total:0`, `prefix:null`, and the empty snapshot
when cleared, including repeated requests with the same cursor. Clients must replace,
not append, on reset. A stale `before` anchor returns 409; refresh from `/sync` instead.
A new transcript with the old message count still resets an old cursor because message
IDs differ.

Fork remains independent: an idle fork copies transcript, provider context, usage,
configuration, settings, tool selection, workspace, and resource references, without
inference or replay. It gets a new ID and fork title and is not owned by the source's
parent delegation. Active forks omit pending input and unfinished work, and discard
opaque provider state that could reference omitted calls; they do not resume that work.

## Settings and instructions

Optional creation `settings` is `{systemPrompt:string,autoApprove:boolean}`; when omitted,
its default is `{systemPrompt:"",autoApprove:true}`. Both fields are required when supplying
settings. Settings replacement is idle-only (409 while working/updating); no live approval
is implicitly resolved by a configuration request. Failed writes block further work.

Workspace replacement uses the same absolute, existing-directory validation and
canonicalization as creation. It is checkpointed before publication and remains available
after reloading an unused session. The first accepted turn locks the workspace, even if
that turn subsequently fails or is cancelled; forks with existing history and legacy
sessions with frozen instructions stay locked. Failed turn validation before acceptance
does not lock it. A concurrent workspace change and send cannot mix folders with stale
project instructions: one may return 409 before acceptance. No operation is retried.
The endpoint is also available over the encrypted remote route; existing frontend flows
remain compatible and need not expose it.

Clients (including Swift) can use snapshot `canChangeWorkspace` to enable workspace
selection. It is false if instructions are frozen, messages or pending input exist, any
operation has been accepted (including failed/interrupted operations), or the conversation
is currently working, updating, closed, or storage-blocked. This field is advisory, not a
reservation: the PUT rechecks eligibility atomically and may return 409 after a concurrent
send or update. Successful PUT returns `200 ConversationSnapshot`; invalid paths/bodies
return 400, unknown conversations return 404, and busy or permanently locked conversations
return 409. Existing clients can conservatively check `configuration.instructionsFrozen`,
`messages`, `pendingInput`, `operation`, and `storageError`; collection summaries omit
`messages`, so prefer `canChangeWorkspace` rather than inferring eligibility from a summary.

Snapshots include `configuration: {settings, instructionsFrozen, workspaceInstructions}`.
The nullable workspace instructions are loaded by the manager from root AGENTS.md at the
first accepted turn, not at session creation. Missing AGENTS.md is frozen as null. Invalid,
linked, nonregular, oversized or non-UTF-8 files reject the turn before acceptance. Each
instruction source is limited to 64 KiB and cannot contain NUL bytes. Instructions are saved
before inference, reused across turns/restart, and never inserted as user transcript rows.
The system prompt can be changed while idle; the project's frozen snapshot is not reloaded.

Settings mutations publish full snapshot frames after settlement, including storage-error
snapshots on failed acknowledgements. A disconnected caller does not abort a settings write.
The API has no client authentication; prompts/project instructions are exposed to reachable HTTP
clients and the selected provider. Auto mode does not sandbox tools or enable any future
desktop capture capability/OS permission.

## Per-session tool selection

Snapshots and catalog metadata include `metadata.disabledTools:[string]`, defaulting to
`[]`. Older saved sessions and clients' snapshots may omit the field; absence means no
tools are disabled. This is session policy, not a shared library default or approval mode.

- Library configuration includes `defaultDisabledTools:[string]`, initially `["shell"]`
  (also when absent from older libraries). `PATCH /v1/library` updates these defaults for
  future sessions only; existing sessions retain their saved selection. Explicit `[]`
  enables all tools by default. Defaults retain names of temporarily unavailable tools.
- Creation accepts optional top-level `disabledTools`; omission inherits the library
  defaults, while `[]` explicitly enables every otherwise available tool. The selection
  is copied and persisted with the new conversation; `null` is invalid.
- `PATCH /v1/conversations/:id` requires `{disabledTools:[string]}` and replaces the whole
  set, rather than adding/removing individual names. Send `[]` to re-enable all tools.
  Success returns the saved snapshot. Updates are idle-only; active operations or a
  blocked storage state return 409. Unknown names and duplicate entries return 400.
- Model requests keep the complete registered tool catalog in stable name order, including
  disabled and temporarily unavailable tools. Selection changes do not rewrite schemas or
  the tool-safety instruction prefix, even when every tool is disabled. No provider-native
  tool allowlists are used.
- Trusted, provider-neutral runtime availability instructions specify the effective enabled
  set (session selection intersected with runtime capabilities). Adapters encode these as
  application instructions: OpenAI `developer`, DeepSeek `system`, never fake user messages
  or unpaired tool results. They are absent from API transcripts, snapshots and UI events.
- The runner checkpoints initial availability and subsequent net changes at model-request
  boundaries, including compaction. Idle PATCH calls only save selection metadata; repeated
  changes coalesce at the next request, and toggling back adds no history entry. Unchanged
  requests reuse the same policy IDs and context prefix. A client may keep a desired set
  locally during active work, then PATCH once idle before its next submission; the backend
  does not queue active-turn selection mutations.
- Disabled tools are rejected before preparation, approval or execution if called anyway;
  runtime capability checks also run again before preparation. Re-enabling affects subsequent
  work; it does not replay denied, interrupted or failed calls. An uncertain write must not
  be retried automatically.
- Sub-agents inherit their parent's selection and cannot change it (PATCH returns 400).
  Forks copy the selection but can change it independently. Both survive save/reload.
  New macOS conversations copy the defaults from Settings → Tools, initially all enabled
  except Shell. Later per-session edits affect only that session.

The macOS selector stays editable during generation, approvals, cancellation and configuration
saves. Checkboxes reflect the latest local choice immediately, with no pending badge or queue
indicator. The existing configuration drain saves only the final desired set once the active
operation settles, before the next command or turn. Streaming snapshots do not overwrite local
choices; toggling back to the saved set requires no write. The current operation (including
steered input and delegated work) keeps its original selection. Save failures remain visible
and block further writes until reconciliation, rather than silently retrying.

Availability history lives separately from the visible transcript in version-11 checkpoints;
versions 1–10 remain readable. Each update has a stable ID and a validated transcript anchor
outside tool-call/result batches. Restore preserves existing updates and records any changed
capabilities at the next request; legacy sessions initialize there without rewriting prior
history. Tool-free conversations with no previous availability need no policy entry.
Children initialize from their inherited selection and their own catalog/capabilities.
Forks copy availability history; clear removes it while retaining `disabledTools`, so the next
request initializes fresh policy. OpenAI compaction explicitly replays the latest covered
availability instruction alongside the opaque summary, then subsequent updates; policy is
not delegated to summary text. These changes facilitate prefix caching but do not guarantee
provider cache hits, particularly across catalog/model/configuration changes.

The bundled app's tool names are `list_files`, `read_file`, `search_text`, `edit_file`,
`shell`, `web_search`, `fetch_content`, `generate_image`, `take_screenshot`, `delegate`, and `wait`.
Names are exact and case-sensitive; a custom backend accepts only its registered tools.
Enabling a tool does not install it, connect a provider, bypass approval, or grant screen
access. Screenshot use still requires a bound native adapter and OS permission. Tool
selection is not an OS sandbox: for example, leaving `shell` enabled still permits approved
shell file operations even if `edit_file` is disabled.

### Quick guide

In the macOS app, choose tools at any time; changes made during work apply to the next turn.
Direct API clients update selection while idle. To keep browsing available but disable shell
commands and direct edits, create with
`{"model":"deepseek/test","workspace":"/absolute/workspace","disabledTools":["shell","edit_file"]}`
(using an available model and existing workspace). Later PATCH that conversation with
`{"disabledTools":["edit_file"]}` to restore shell, or `{"disabledTools":[]}` to restore all
tools. Read `metadata.disabledTools` from the returned snapshot to display the saved choice.
Auto/manual approval remains a separate setting.

## Wait tool

The service registers `wait` independently of `--workspace-tools`. Its required arguments are:

```json
{"duration_seconds":60,"description":"Waiting for CI checks","wake_prompt":"Check the existing CI run. If still pending, wait again."}
```

`duration_seconds` is an integer from 1 to 86,400. `description` is nonempty single-line display metadata, at most 160 UTF-8 bytes. `wake_prompt` is nonempty text, at most 4,096 UTF-8 bytes. Unknown fields and NUL bytes are rejected. The wait itself needs no approval; subsequent actions retain their usual validation and approval rules.

The call pauses the current operation and must be the only tool call in its response, with a model step remaining for continuation. Mixed batches and last-step waits fail before execution. Expiry returns `{"elapsed_seconds":60,"wake_prompt":"..."}` as ordinary tool output; the runner continues in the same operation. Rechecking may lead to another one-shot wait, subject to the normal step limit, never an unbounded recurring schedule. The prompt does not grant authorization or permit automatic retries of failed/interrupted actions.

While waiting, `operation.state` remains `running`, `activeToolCallID` identifies the call, and `activeToolName` is `wait`. The latter is derived metadata, also included in catalog summaries; older clients may ignore it. Stop, deletion, and shutdown cancel the timer and await settlement. Restart marks unfinished waits interrupted, without resuming timers or inference. New steering input queues for the next model decision rather than waking early. Disconnecting an observer or closing a session window does not cancel backend work.

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

`tool_started` means the executor was entered after approval and successful intent checkpoint, not that effects succeeded. Every finalized call receives one `tool_finished` result event, including denial, preparation failure, interruption, and non-execution. Terminal outcomes are `completed`, `denied`, `failed`, `interrupted`, `not_executed`. Delegation may also persist a nonterminal `running` tool message (see [incremental delegation presentation](#incremental-delegation-presentation-contract)); it emits only `message` updates until settlement. Calls that never enter their executor have no start event. Message events still accompany tool results; reconcile by message ID. Abrupt exit can prevent delivery; reconnect/recovery uses snapshots, not replay.

Tool events are not durable acknowledgments. A result may precede its checkpoint. A completed tool result remains completed if cancellation arrives after publication; cancellation at the executor/result handoff is conservatively interrupted with possible effects.

Subscription and initial snapshot have no update gap. There is no replay cursor, heartbeat or automatic reconnection. Streams stay open after terminal operations to observe later turns. Slow observers are disconnected rather than blocking inference: queues are bounded to 5 MiB (one larger snapshot is permitted). Clients bound responses/frames to 32 MiB. Reconnect explicitly after interruption; never resubmit automatically. The macOS and iOS conversation views use incremental `/sync` reads instead of this event stream; native screenshot requests still use their separate authorized channel.

```sh
curl http://127.0.0.1:8765/v1/health
curl --no-buffer http://127.0.0.1:8765/v1/conversations/CONVERSATION_ID/events
```

## Shutdown and recovery

`service.close().await` stops accepting connections, disconnects observers/partial requests, settles catalog mutations, cancels runs, awaits cooperative provider/tool cleanup and final checkpoints, then closes the manager/store. Noncooperative adapters can delay shutdown. Normal shutdown releases the TCP listener and removes the store lock. Forced termination is not a clean tool shutdown.

Crash recovery never resumes work or steals ownership. Verify the old host and its tool processes have stopped, then explicitly remove only the stale `conversations/.lock` for that profile. See [architecture.md](architecture.md#storage-and-recovery) for interrupted intent, missing results and possible side effects.

Tests cover these contracts with fake providers/transports and real network-bound TCP connections/subprocesses. Live OpenAI/DeepSeek, Linux deployment, browser OAuth, native OS permission behavior and Swift UI integration are not claimed verified.

## Context after failure or interruption

Failed and interrupted assistant replies remain in provider context, including partial
text or a notice when no text was returned. A runtime annotation marks them as incomplete
and states that no tool calls from that response executed. Unfinalized calls are never
replayed. Finalized calls retain their paired results, including failed, denied,
interrupted and unexecuted outcomes. Streaming output, running tool progress and
transcript-only compaction activity remain excluded. Stable context IDs, recovery and
compaction use the same projection; saved transcript text and status are unchanged.
Nothing resumes or retries automatically after failure or cancellation.

## Steering

Steering targets an exact active operation; stale, cancelling or settling operations
return 409. Ordinary turn submission still rejects a busy conversation. Accepted steering
input is observable in `pendingInput` (up to 32 messages), checkpointed by the runner while
streaming, awaiting approval or executing, and incorporated only after all finalized calls
have outcomes. The `input` event contains `messageID`; later message events reconcile the
same ID when incorporated. Steering is additive: the in-flight provider response and its
tool-call batch finish normally, including preparation, pending approvals and execution.
New input neither withdraws approval nor supersedes calls already requested by that response.
The model receives the results and queued input together at its next decision. Use explicit
denial or cancellation to stop an action; steering does not grant approval or cancel work.

Like turn submission, 202 is in-memory acceptance, not a durable receipt. A crash before
its checkpoint can lose newly accepted input. Checkpointed pending input survives restart
but never starts inference itself; the next explicit turn incorporates it before new input.
Cancellation or step-limit failure can retain pending input for that next explicit turn.
Version-3 checkpoints retain pending input; older versions are read conservatively.

## Sub-agent delegation

Top-level sessions created through the session API, restored sessions, and explicit forks
expose `delegate({"task":"...", "title":"Parser review"})` for one child or
`delegate({"tasks":[{"task":"first independent task", "title":"Parser review"}, {"task":"second independent task", "title":"Test review"}]})` for concurrent
children. Supply exactly one form. The tool waits for all children and returns results in
task order; ordinary tool calls remain sequential. This reuses the existing agent runtime:

- The manager persists a normal child conversation before inference. Its optional
  `metadata.parent` is `{sessionId, operationId, toolCallId}`, identifying the managing
  session and the exact delegation call. Top-level sessions omit `parent`; clients must
  tolerate its absence. The explicit `title` supplies the child's initial title; `task` supplies its first user message.
- Children inherit the parent's model, workspace, settings and frozen workspace
  instructions. They do **not** copy its transcript, opaque provider state, attachments,
  or transient native screen-access grants. Put necessary context in `task` (nonempty,
  at most 16 KiB). Workspace files are shared, not sandboxed or worktree-isolated.
- The child uses ordinary tools and the inherited approval policy. Approvals remain on
  the child's session and are resolved through its existing approval endpoint. The parent
  waits without requiring a frontend to remain attached. Child sessions do not expose
  `delegate`. Each session has an independent 128-model-step budget; child steps do not
  consume the parent or sibling budgets.
- Each task is nonempty and at most 16 KiB; batches contain one to eight task objects.
  Every task requires a nonempty, single-line `title` of at most 60 characters, with no
  control characters. All tasks and titles are validated before any children are created.
  The entire batch reserves against an eight-child **parent user-turn** limit before any
  child starts. Cleanup and compaction do not refund reservations. Queued steering input
  resets this budget only when consumed at the safe boundary after previous executors
  settle, even though the operation ID stays unchanged. Coalesced inputs share one budget;
  replay protection remains operation-wide. Avoid conflicting writes to shared files.
- Each settled child's bounded result is checkpointed in the parent's running tool message,
  then that child is deleted immediately, without waiting for its siblings. This includes
  child failures and individual user cancellations. Failed checkpoints retain the child
  and the in-memory result for inspection, block further saves/work on the parent, and
  never trigger cleanup or retries. Failed deletion retains the saved result and any
  session not actually removed; cleanup is not retried by the final-result hook. Automatic
  cleanup also never retries a failed explicit deletion of the same child.
- The tool continues owning all remaining executors and returns **one combined result to
  the parent model only after all children and their checkpoint/cleanup attempts settle**.
  Results stay in original task order. A failed child never retries or cancels siblings;
  single-child failure retains a failed tool outcome. Batch results report each child
  separately. Combined text is at most 32 KiB UTF-8, including task headings, child IDs,
  truncation markers and terminal notices, divided fairly among children.
- Parent cancellation cancels unfinished children and waits for executor cleanup. Already
  published results remain saved; unfinished children are retained unless the user
  explicitly deletes the family. Restart retains partial results, marks unfinished
  operations interrupted and resumes neither inference nor cleanup. Active forks omit
  running partial tool messages and their unresolved calls, never turning them into
  completed context. New turns/compaction on a child are blocked while its managing
  operation is active; approval, steering and cancellation still use the child's own IDs.
- Deleting a running child cancels its operation and waits for executor cleanup; its
  parent receives a `cancelled by user` tool result and continues without retrying.
  Deleting a parent cancels the entire family and deletes its sub-agents in the same
  request, children first. Deletion remains pending until tool cleanup has settled.
  Storage failures stop the cascade without retrying, retaining
  the parent for inspection. Managed files, images and shell logs use the existing
  reference checks: assets referenced by independent sessions/forks are preserved,
  and unreadable records conservatively block asset cleanup. Explicitly forking a
  child creates an independent top-level session, outside the deletion cascade.

Children appear in ordinary catalog/snapshot endpoints while retained. Delegation tool
cards show task inputs and results, not links to child sessions. macOS provides compact,
single-line, undated child rows beneath the parent title, followed by its shortcut,
workspace and date line. Child rows span the group width, share the parent's horizontal
padding, and use the footer's font size. Native row height grows and shrinks with the
children without replacing the parent row. Clicking a child opens its transcript and
composer; steering uses the child's active operation, including while awaiting approval,
and never starts a competing turn. Child rows show approval/attention indicators but
no spinners or arrows, and are not standalone sessions or keyboard-shortcut entries.
There is no Sub-agents menu
or parent-navigation button. Children disappear after their results are saved; the
parent's saved tool result remains. Explicit child deletion returns selection to its
parent without disabling/dimming the sidebar. Explicit macOS deletion of a running
session, or a parent with running children, requires native confirmation with Cancel
as the default; idle deletion and automatic cleanup do not prompt. Local unsent drafts
are preserved if automatic cleanup occurs while the user is composing.
Version-9 records persist the parent relationship. Version-10 records add delegation
progress; versions 1–9 remain readable. Partial publication requires at least version 10
and never downgrades version-11 availability history. Low-level embedders using
`AgentManager::create` retain control over
their explicit tool list; `create_session` and `fork` require an `Arc<AgentManager>` to
install delegation safely.

### Incremental delegation presentation contract

Reuse the existing tool message, not an extra transcript row or provider message:

```json
{
  "role": "tool",
  "id": "stable-message-uuid",
  "callID": "original-delegate-call-id",
  "outcome": "running",
  "text": "Task 2\nChild session: child-uuid\n\nBounded answer",
  "details": {
    "type": "delegation",
    "total": 2,
    "results": [{
      "taskIndex": 1,
      "sessionId": "child-uuid",
      "outcome": "completed",
      "text": "Task 2\nChild session: child-uuid\n\nBounded answer"
    }]
  }
}
```

`taskIndex` is zero-based original input order. `results` contains only settled children,
ordered by that index, with child outcomes `completed`, `failed` or `interrupted`.
`text` is ready for the existing result body: ordered sections joined by blank lines.
The first settled child creates this message; subsequent children and final settlement
replace it using the same `id` and `callID`. There is no empty placeholder. The existing
`message` event carries each checkpointed update; `activeToolCallID` stays on the delegate
through execution/cleanup. **`running` is not a terminal tool outcome**: no
`tool_finished` event or provider-visible tool result is produced for partial updates.
At final settlement the message receives the ordinary terminal outcome and one
`tool_finished` event; its details survive failure/cancellation/recovery.

Snapshots and `/sync` include the same message. The sync cursor already includes the
mutable tail message, so clients reconcile by ID rather than append another result.
Intermediate reads can see an unacknowledged checkpoint; `storageError` marks a failed
save, and no child is automatically deleted until its own result's save succeeds.
The sum of child `text` fields plus separators fits the same output budget (not 32 KiB
per child); envelope/structured metadata is additional bounded overhead.

For `shared/ExecTranscript`, map the message's `text` and `outcome` to
`ToolDisplayResult(text:outcome:)` for the original delegate call and retain the active
execution state from `activeToolCallID`. `ToolPresentation` already shows delegate inputs
and `result.text` in the result body. Decode the new `delegation` details and `running`
outcome without treating result presence alone as completion; no card layout change is
required. The backend does not synthesize progress hints or unfinished-child text.

Read-only catalog access (`AgentManager::snapshot` / `observe`, HTTP snapshot, `/sync`,
`/events`) remains available during child deletion reservations, until actual catalog
removal. The mutation-capable `get` handle and all mutation reservations stay guarded.
After removal, new reads return 404; a failed deletion leaves the session inspectable.

Sub-agents cannot use `generate_image` or `take_screenshot`: both definitions and
executors are removed from new and restored child sessions. Delegation currently returns
text, not durable managed-image ownership. Generate/capture images in the parent session
instead; child asset transfer is not supported.

## Session library

`metadata` contains `title` (nullable before first input), `manuallyNamed` and `activityAt`
(Unix milliseconds). The first prompt supplies a fallback title; manual names are retained.
Rename/model changes are idle-only and checkpointed before publication. Forks preserve
transcript IDs and frozen instructions in an independent conversation; they never resume
work or mutate the source. Forking does not wait for an active turn: the backend snapshots
under the conversation lock, omits streaming assistant output and queued input, and keeps
completed tool results with their matching calls. Calls without results are omitted rather
than resumed or replayed. The fork has no live operation or approval; an active source
operation is marked interrupted in the copy. Opaque provider context and usage are cleared
for active forks so continuation is rebuilt from the retained transcript. Existing failed
or interrupted transcript entries remain unchanged. Shell/image resource references are
shared until the last referencing fork is deleted; transient native permissions are never forked.

`GET/PUT /v1/library` owns shared `defaultModel` (nullable), new-session `settings`, and
`order` (up to 10,000 unique conversation UUIDs). Omitted creation model/settings use these
defaults; workspace remains explicit. Order IDs missing from the catalog are harmless and
ignored. Unlisted sessions follow in stable ID order. `library.json` is atomically saved in
the private conversation store. Failed library writes block library mutations/default-based
creation until reload; existing conversation execution is independent. Corrupt library data
fails startup rather than silently resetting preferences. Clients retain their own selected
session, drafts, windows and scroll state.

Accepted library updates/patches, session creation, forks and deletions own their settlement
and publication even if an embedded caller drops its future (or an HTTP client disconnects).
`GET /v1/library` returns 409 while a library write is pending, never the old configuration.
A fresh successful GET can resolve a lost client acknowledgement only after settlement; a
GET started before the write cannot. A failed storage acknowledgement leaves reads at 500
until profile reload, even if the file was committed. Neither pending nor failed reads clear
client write uncertainty. Existing conversations can still execute independently.
Detaching is not cancellation and is not authorization to resubmit. A failed creation/fork
acknowledgement may follow a committed write; its session remains catalogued but closed to
new work until explicit deletion or reload, preserving potentially shared asset ownership.

### Deletion recovery

Before removing a transcript, the manager saves a private `conversations/.<id>.deleting`
manifest containing only that session's known asset ownership and parent ID. The manifest
survives until assets are removed or have another durable owner. Neither restart nor a
failed acknowledgement automatically retries deletion. In particular, an explicit retry of
DELETE can confirm an already-missing transcript **only** with owned deletion intent;
ordinary missing records are not silently accepted.

If asset storage is unavailable, another record is unreadable, a possible owner has an
unacknowledged creation/fork write, or cleanup fails, the manifest remains recoverable.
Uncertain in-memory ownership alone cannot retire durable cleanup intent. Pending cleanup
IDs whose transcripts are gone appear in the existing
`unreadable:true` catalog entries and reject ordinary reads/work. Inspect the profile, repair
or explicitly delete blocking unreadable records, then explicitly DELETE the pending ID
again. Deleting a parent also includes pending child manifests after restart. Do not delete
manifests to dismiss these entries: doing so discards cleanup ownership. Corrupt or unsafe
manifests fail startup without overwriting them. Explicit recovery tolerates partially
committed asset unlinks, but never sweeps unreferenced assets, follows unsafe links, or
guesses ownership from corrupt transcripts.


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
The standalone registry also registers `web_search` as a runner tool, independently
of workspace file/shell opt-in. Queries are public single-line text (DeepSeek: at most 128
characters); results contain up to ten unique credential-free HTTPS source URLs and bounded
excerpts. Sources and excerpts remain untrusted evidence. This is not URL fetching and
executes no JavaScript. Search consumes provider service access and is never retried.

`GET /v1/providers/deepseek/balance` returns `{amount,currency}` arrays, keeping exact decimal
amounts as strings rather than floating point. These services use bounded JSON bodies,
provider deadlines and explicit cancellation. Read-only results started before a credential
change are rejected instead of being presented under the new account. They do not mutate
conversation context unless invoked as a runner tool. `toolsEnabled` in health describes
workspace file/shell tools only; search, fetch, image generation and optional native capture are independent.

Live provider compatibility is unverified;
tests use synthetic credentials and fake transports, not the live service.

## Public content fetching

`POST /v1/fetch` accepts `{url}` and returns `{url,contentType,text,truncated}`. The same
operation is registered as `fetch_content` in the standalone runner. No provider credentials, website credentials, cookies or ambient proxies are
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

## Effort, provider context and token usage

Session settings accept optional `effort`: null means the provider/model default. DeepSeek
supports explicit `none` (thinking disabled), `low`, `high`, `max` (thinking enabled).
Unknown DeepSeek effort IDs fail before transport; actual model availability is still
provider-dependent. `effort ID LEVEL` or `effort ID default` updates an idle session.
Models may return `efforts:[{id,name}]`, `defaultEffort` and `acceptsImages` metadata. Image
metadata gates image upload delivery to the selected provider; unsupported user image input fails without sending inference.

Successful responses may publish `usage:{inputTokens,outputTokens,totalTokens}` in snapshots.
Counts are optional provider measurements, not estimates or attributable account cost.
Usage is cleared for a new response/model selection rather than presenting stale values.
Snapshots additionally expose nullable `contextUsage:{tokens,limit}` from provider measurements and model metadata; clients may calculate a display percentage. See runner-owned compaction below.

Opaque per-conversation provider state is stored in version-4 checkpoints, never in API
snapshots or user/model transcript text. DeepSeek retains reasoning only as needed to echo
completed assistant tool calls in later requests. Reasoning streams are bounded at 4 MiB;
combined opaque state is bounded at 8 MiB. Partial/failed streams cannot commit staged
provider state or measurements. Versions 1–11 remain readable; new records start at
version 9 and upgrade for delegation progress (10) or runtime tool availability (11).
Thinking and non-thinking responses still require supported completion and `[DONE]`; no
inference or rotating-token retries are introduced. Mock transport tests do not verify
live model effort availability or service compatibility.

## Provider routing

Standalone composition uses a provider registry. Discovered IDs are qualified (for example
`deepseek/deepseek-chat`) and include optional `provider` metadata; clients should treat model
IDs as opaque values. Existing unqualified DeepSeek IDs remain aliases for the configured
default provider. Credential and balance routes continue to use provider IDs such as
`deepseek`, not model IDs.

The registry owns per-provider opaque context envelopes. Switching models/providers is
idle-only; each provider receives only its own saved state while generic completed history
remains conversation-owned. No mutable response context is shared across conversations.
Embedding can register additional ChatProvider implementations; the standalone service
registers DeepSeek and OpenAI subscription adapters. Concrete wire models remain inside their adapters.

Discovery keeps last-successful catalogs in memory and private JSON, falls back with explicit warnings on
refresh failure, and invalidates cached data around credential changes. Read
`GET /v1/model-warnings` after discovery to inspect safe diagnostics; no provider bodies or
account identifiers are exposed. Disconnected providers are excluded. Account-scoped model/account metadata is persisted privately in `metadata.json` and restored conservatively as stale. Unreadable/insecure optional caches are not repaired and do not block history. Discovery does not retry automatically.

## Retained shell logs and resource references

Managed workspace shells retain combined output in private `PROFILE/shell-logs/UUID.log`
files (0600, parent 0700), up to 64 MiB per invocation. Output is still drained after the
retention limit; truncation/write/drain failure is reported as a partial log, never a full
one. A truncated tool result points to the retained file for a separate inspection rather
than repeating the command. `description` is optional shell-call display metadata; it
never changes the exact command or authorization. Embedders using `create_workspace_tools`
without a log store keep bounded output only; standalone workspace tools use managed logs.

Snapshots/checkpoints expose `resources:[{id,callID,kind:"shell_log"}]`. The runner reserves
these references with execution intent before effects. A reference does not prove a file
exists or the command started: cancellation/recovery may leave only a reservation.
`POST /v1/logs/:id` with `{offset,maxBytes}` reads up to 32,768 bytes and returns
`{text,offset,nextOffset,totalBytes,endOfFile}`. Offsets count raw bytes; text is UTF-8-lossy
when a boundary splits a character. EOF is a point-in-time file observation, not proof that
an active command or output capture completed. Unreferenced IDs return 404. Log output remains untrusted data.

Forks retain shared references. Deleting a conversation durably removes its checkpoint,
then removes logs only when no remaining conversation references them. Fork creation is
excluded from deletion cleanup until its record settles. Unreadable sessions cause
conservative retention because their references cannot be proven absent. Cleanup failures
can occur after deletion took effect; inspect state, never automatically repeat deletion.
Abrupt crashes can leave orphan files; they are not automatically promoted or replayed.
Version-5 records retain resource references; earlier record versions remain readable.

## Typed tool details

Tool transcript messages may include `details` on completed outcomes only:
- `{type:"edit",path,diff,truncated}`: applied edit and a bounded contextual unified diff.
- `{type:"search",result:{query,answer,sources}}`: source-bearing search evidence.
- `{type:"page",content:{url,contentType,text,truncated}}`: directly fetched page text.

Pending edit approvals expose the same edit preview in `approval.details`; this is a
proposal, not evidence of execution. Denied, failed, interrupted and not-executed results
have no applied details. Diff previews over 64 KiB are explicitly truncated and must not
be treated as complete patches. The exact prepared replacement/revision remains the
authority for execution. Typed details are presentation data: provider context still sees
neutral tool text/outcomes, not frontend rendering structures. Legacy text-only executors
remain usable; richer executors produce text and typed details in one execution, never
repeat a tool merely to obtain presentation metadata.

## Search-model selection

Session/new-session-default settings accept optional `searchModel` (null follows the chat
model). `search-model ID MODEL` or `search-model ID default` updates an idle session. The
runner supplies this configuration to the search tool; the model cannot silently choose
a different provider through tool arguments. The provider registry routes qualified search
models independently of the main chat model. An explicit cross-provider choice sends public
search queries to that selected provider, so frontends must present the selected search
model/provider accurately. There is no implicit cross-provider fallback on failure.

`configure` updates prompt/approval policy while preserving effort/search selection.
Version-6 records persist this setting; versions 1–5 remain readable with no search override.

## OpenAI subscription authentication

Standalone startup registers `openai` alongside `deepseek`. OpenAI is ChatGPT/Codex
subscription access, not public API-key authentication. An absent OpenAI entry is disconnected
and never prevents local history access. `OPENAI_SESSION_JSON`, when explicitly supplied,
overrides only the OpenAI JSON entry and remains externally managed: expired environment
sessions cannot be rotated or disconnected through the API. Malformed credentials fail
closed; the service never repairs an insecure credential file.

| Method | Path | Contract |
|---|---|---|
| POST | `/v1/providers/openai/connect` | `{}` → `202 {attempt,authorizationUrl}` |
| GET | `/v1/connection-attempt` | Nullable `{id,provider,state,error}`; never includes the authorization URL |
| POST | `/v1/connection-attempt/cancel` | `{operationID:attemptID}` → `202 {accepted:true}` |
| DELETE | `/v1/providers/openai` | Local disconnect after one remote revocation attempt; failed revocation may follow successful local removal |

The manager owns one connection attempt, excludes account changes/new turns during it,
and keeps history readable. Attempt states are `running`, `completed`, `failed`, and
`interrupted`. Authentication continues independently of a dropped HTTP caller; an explicit
cancel targets its exact attempt. Shutdown cancels the attempt and awaits its settlement.
The challenge URL is returned only to the initiating HTTP client, never logged or
included in provider status. Do not log this response. Swift opens the system browser
without printing the URL. The auth status and cancellation HTTP endpoints observe/control it.
DeepSeek keys are configured through the provider HTTP endpoint or private startup credentials.

OpenAI authentication uses random state/nonce, S256 PKCE, an IPv4 loopback-only callback on
port 1455 at `/auth/callback`, bounded HTTP parsing, exact Host/state validation, unique query
fields and a five-minute callback deadline. No public OAuth callback or remote login proxy
is provided. Identity acceptance requires RS256 verification against the fixed OpenAI JWKS
origin, exact issuer, audience/authorized-party, expiration/not-before, nonce and subject.
The access-token account claim is read only for routing after an authenticated HTTPS token
exchange; locally decoded JWT claims are not treated as proof of authorization.

The provider-owned JSON session has `accessToken`, `refreshToken`, `accountId`, `subject`,
`expiresAt` (Unix seconds), and `requiresReconnect`. Never expose it in UI, logs, tools or
conversation state. Credential updates serialize across both providers and preserve the
other entry. Refresh is single-flight across conversations. Before sending a rotating
exchange, persist `requiresReconnect:true`; only after a valid replacement is durably saved
may credentials be released. A lost response, changed account, invalid replacement or failed
save leaves the session blocked. Restart cannot reuse that consumed token. Cancellation of
one inference detaches from refresh; shutdown waits for rotation/persistence to settle.
There is no automatic token-exchange retry. Reconnect explicitly after inspecting status.

OpenAI Responses requests disable storage, request encrypted reasoning, use strict tool
schemas and preserve complete output in provider-owned per-conversation state. Deltas are
provisional: terminal text snapshots replace them, and calls/state/usage become valid only
on terminal success. Completed output items omitted from terminal output are retained;
failed/incomplete responses release no calls. Opaque context is account-bound and checked
against completed transcript text/calls. The runner does not interpret Responses JSON.
Redirects, cookies, ambient proxies and retries are disabled. JSON account/auth requests
have a 30-second deadline; image responses and complete Responses streams have a 600-second
bound (Responses headers: 120 seconds). SSE output is bounded to 16 MiB total, 5 MiB per
frame, and 4 MiB retained output/text. OpenAI chat requests are capped at 32 MiB.

## Account observations and metadata caches

`GET /v1/providers/openai/usage` returns
`{windows:[{durationSeconds,usedPercent,resetsAt}],fetchedAt,stale}`. Reset times use Unix
seconds; `fetchedAt` uses Unix milliseconds. Empty windows mean no valid allowance windows
were supplied, not unlimited quota. Percentages are measured values, not forecasts.
No per-run before/after observations are added.

`GET /v1/metadata` returns per-provider
`{provider,modelsFetchedAt,modelsStale,usageFetchedAt,usageStale,balanceFetchedAt,balanceStale}`.
Nullable timestamps mean unobserved. Account observations use a 30-second cache; model
freshness ages after five minutes and discovery remains explicitly requested. A failed
refresh can return a same-account cached observation marked stale; no refresh is retried.
Use this metadata when displaying DeepSeek's exact-decimal balance array.

`metadata.json` contains bounded private catalogs/observations keyed by a provider-internal
credential/account fingerprint. Fingerprints are not exposed via the API. Credential
changes invalidate caches; observations crossing a change are rejected. Restart marks
restored account/model observations stale. A cache for another account is never used.
Corrupt, linked or insecure optional cache files are not overwritten/repaired and do not
block local history. Warnings are safe fixed diagnostics, never raw provider responses. An uncertain cache save
disables further cache writes until restart; it does not retry or block conversation history.

## Runner-owned context compaction

`POST /v1/conversations/:id/compact` with `{}` returns `202 {operationID}`.
This starts an exclusive runner operation, not a manager/provider side loop. The same
operation-targeted cancellation and terminal durability guarantees apply. Manual compaction
rejects pending input/busy sessions and models without compaction support. Once accepted,
manual compaction accepts `/steer` input through the same operation-targeted queue as a turn.
After successful, durable compaction, queued input starts a response within that operation;
without queued input it finishes without inference. Failure or cancellation retains pending
input without resuming inference. A rejected or uncertain queue request is never retried as
a new turn.

The OpenAI provider supports manual compaction and automatic compaction at 95% of the
last completed measured context window. Before inference the runner prepares required
model metadata. Automatic compaction includes finalized history/tool outcomes and explicitly
marked failed/interrupted replies, but excludes
new trailing user input; accepted steering is checkpointed while the request is in flight.
The provider appends the Responses v2 `compaction_trigger`, accepts exactly one encrypted
compaction item, and discards incidental text/calls without executing them. There is no
obsolete `/responses/compact` call and no implicit text-summary fallback for DeepSeek.

The opaque replacement is checkpointed before further inference. Visible messages and
stable IDs remain unchanged. Failure/cancellation retains the original context; uncertain
checkpoint acknowledgement blocks work. A successful compaction clears stale token usage
until the next ordinary response measures it. `contextUsage:{tokens,limit}` is a completed
provider measurement, not an estimate of newly appended input. Neither compaction usage
nor stale pre-compaction usage is presented as the replacement context's size.

## Local file attachments

`POST /v1/conversations/:id/files` accepts `{name,base64}` and returns `201 FileRef`:
`{id,name,path,byteCount,sha256}`. Files are opaque bytes, up to 8 MiB each (including empty
files); unsafe filenames, directories and symlinks are not accepted by the native importer.
No PDF parser, OCR, provider upload or software installation runs during attachment import.
The composer accepts up to four mixed image/file attachments; images retain their existing
normalization and byte limits.

New turns and steering accept optional `files:[assetID]`, at most four file IDs. IDs must
belong to that conversation; clients cannot submit arbitrary local paths or forged file
metadata. File-only messages are valid. Snapshots persist `files:[FileRef]` on user messages;
the displayed message text remains unchanged. The provider-neutral context adds a JSON
manifest of managed absolute paths and shell usage instructions, not the file contents.
The agent uses the existing shell tool and approval policy to read selected lines, run
analysis, or invoke installed PDF/document utilities. Parsing support depends on installed
utilities; the agent must report missing tools or extraction limitations, and must not
execute an attachment or install software just because a file was dropped. File contents
and names remain untrusted data. Filesystem tools still restrict paths to the workspace;
managed paths outside it are accessed through the shell.

Original copies live under private `PROFILE/session-files/SESSION/ASSET/FILENAME`, with a
small `ASSET.json` lookup manifest alongside the session directories. These are session
scratch assets, retained across restarts rather than placed in purgeable OS temporary
storage. Copies are created read-only (0400); this is an accidental-write safeguard, not a
sandbox against shell commands running as the same user. Working copies and outputs belong
in the workspace. Files are retained until the last owning conversation/fork is deleted;
unreadable sessions conservatively prevent cleanup. Upload ownership is checkpointed before
storage. Failed/uncertain uploads are never automatically repeated; unused uploaded files
remain owned until conversation deletion. Incomplete crash artifacts are not promoted.

Uploads are allowed during an active turn. Steering keeps the original operation ID across
upload; a rejected/uncertain queue request never becomes a fresh turn. Accepted queued file
references survive cancellation/restart without replay. Version 8 adds file references;
versions 1–7 remain readable.

## Image assets, inputs and generation

| Method | Path | Contract |
|---|---|---|
| POST | `/v1/conversations/:id/images` | `{name,base64}` → `201 ImageRef`; conversation-owned upload, including during active turns |
| GET | `/v1/images/:assetID` | `{image:ImageRef,base64}` for an asset referenced by an available conversation |
| DELETE | `/v1/conversations/:id/images/:assetID` | Release an unused upload → `{released:true}`; cannot remove history independently |
| POST | `/v1/conversations/:id/turns` | `{text,images?:[ImageRef]}`; image-only input is accepted |

`ImageRef` is `{id,name,mediaType,width,height,byteCount,sha256}`. Snapshots/checkpoints carry
references, never encoded image bodies. PNG/JPEG data is fully decoded with allocation and
dimension bounds: 8 MiB per image, dimensions 1–8192, at most 32 million pixels, no APNG,
and eight images / 16 MiB per input. At most two asset validations run concurrently. Active provider image context is also capped at 16 MiB;
provider encoded-request bounds can be stricter. References are validated against immutable
asset bytes before delivery. Unsupported user image input fails without sending inference.
Tool images are delivered only to image-capable models; other models receive explicit
context that image contents were unavailable, never a claim of visual inspection.

Assets live at private `PROFILE/images/UUID.image`. Publication uses synced private staging,
exclusive no-overwrite linking and directory sync. The runner reserves generated/capture
resource IDs with execution intent before effects. Upload reservations are durably attached
before bytes are published. Failed/interrupted work can therefore leave reservations
without files, or a retained artifact without a completed tool result. Never regenerate to
resolve that uncertainty. Uploaded images can be released only while unused by history;
conversation deletion removes remaining references after its durable checkpoint deletion.
Forks share immutable assets. Last-reference cleanup is excluded from live forks, and
unreadable sessions cause conservative retention. Orphan files/staging are never replayed
or promoted automatically. Version 7 adds images; versions 1–6 remain readable.

The `generate_image` tool uses the one image-generation provider selected by composition
(OpenAI in standalone), not a concrete wire model chosen by a frontend/tool. Ambiguous
multi-image-provider registry composition is rejected; there is no provider fallback.
Generation uses the same runner approval/cancellation/intent/result lifecycle as other
tools. Only request it for an explicit user image request. It consumes subscription quota,
never writes directly into a workspace, and is never retried automatically. Completed image
results have `details:{type:"image",image:ImageRef,origin:"generated"|"screenshot"}`.
A managed source is read-only: copy it explicitly, never regenerate just to save it.
OpenAI hosted search uses a separate Responses request and does not mutate chat state.

Image rendering, draft attachment selection and file-save presentation stay in Swift.

## Optional native screenshot protocol

**There is no backend screen capture.** The Swift adapter owns screen/window
capture and OS permission. Registration uses the same HTTP API but requires a **second,
independently provisioned capability**: configure `EXEC_AGENT_NATIVE_TOKEN` on the backend
and the trusted adapter, then send it as `X-Exec-Native-Token` in addition to normal API auth.
It must be a distinct 64-hex secret. Without it all `/v1/native/*` operations and `PUT
/v1/conversations/:id/desktop` return 403. Ordinary API clients never receive this secret.
The macOS app generates a fresh native secret for its own bundled helper and never attaches
to an external backend. Other trusted adapters can be provisioned independently for standalone
hosting. The native header is sent only for native operations.

TCP does **not** provide process attestation or same-host guarantees. The native secret
explicitly trusts its holders to register adapters, report OS permission, enable/disable
sessions and return correlated captures. It is not per-frontend/multi-tenant isolation.
The adapter enforces actual OS permission; the tool runner enforces conversation consent. A live, explicitly bound channel is required. Fully trusted API administrators can
execute host tools: these credentials are not an OS sandbox against same-user code.

| Method | Path | Contract |
|---|---|---|
| POST | `/v1/native/events` | `{osScreenPermission:boolean}` → live NDJSON: `registered`, `request`, `cancelled`, `ping` |
| PUT | `/v1/native/permission` | `{frontendID,granted}`; update the registered frontend’s reported OS permission |
| POST | `/v1/native/results` | `{request:NativeRequest,result:NativePayload}`; exact, live, single-use correlation required |
| GET | `/v1/conversations/:id/desktop` | `{frontendID,enabled}`; initially disabled |
| PUT | `/v1/conversations/:id/desktop` | Bind one frontend or disable; binding alone grants neither tool consent nor OS permission |

The registration event supplies `frontendID`. `NativeRequest` is
`{id,frontendID,conversationID,operationID,callID,action:{target,windowID}}`.
Targets are `desktop`, `list_windows`, `window`; only `window` takes a positive `windowID`.
Window capture requires a prior successful enumeration through the same frontend/session.
Results are `{type:"windows",windows:[{id,title}]}`, `{type:"image",base64}` or
`{type:"failed"}`. Window lists are bounded to 256 unique positive IDs and 1024-byte titles.
Window results have typed `details:{type:"windows",windows}`. Titles/screens remain
untrusted evidence, not instructions. Failed native results expose no arbitrary frontend
error string.

Capture preparation binds the exact frontend/action without requesting OS access. Manual mode asks once per conversation for screen access; Auto mode permits requests without storing manual consent. The runner checkpoints intent before sending the request. The adapter requests OS permission on first authorized use if needed.
Results must match every correlation field and the live registered frontend; stale, wrong-target,
duplicate or post-cancellation results return 409. A 60-second deadline, disabled/rebound
session permission, revoked OS permission, disconnect or cancellation invalidates the
request. Cancellation notifications are best-effort bounded transport messages; acceptance
of late results never depends on notification delivery. No request is replayed or rerouted.
The native adapter must cancel its own capture work when notified or disconnected.

OS permission reports are claims from explicitly authorized adapters; the backend cannot
verify macOS TCC on behalf of Swift and never grants it. Reporting OS permission restored
does not restore manual conversation consent. Native permissions/channels are transient, never restored
or forked. General observer disconnects still only detach; disconnecting the bound native
capability channel specifically revokes that capability and invalidates its pending calls.
The macOS app
implements the local adapter and on-demand screenshot permission flow; see
[architecture.md](architecture.md) for its permission flow and verification limits. There is no
headless capture substitute.

### Automatic session titles

Library configuration includes `automaticTitles` (default `true`, including older saved configurations). At acceptance of each new user turn the manager applies this preference. The runtime runs isolated, tool-free title inference with the session model before chat inference, bounded to 15 seconds and cancellable with the operation. Failures retain the existing title without retry. Manual rename persists `manuallyNamed` and permanently suppresses automatic naming, including after restart. Naming shares operation ownership and checkpoints; it never appends to chat context. Setting changes apply to subsequent turns, not already accepted operations.

