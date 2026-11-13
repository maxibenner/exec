# Agent HTTP service — API v1

The HTTP API extends the TypeScript sketch with session configuration and deletion. New conversations now default to auto-approval; clients requiring individual approvals must explicitly request manual mode. The service owns the manager, provider, tools, approvals and JSON persistence; clients never run another agent loop. The Swift app launches the bundled backend and consumes this API.

## Standalone startup and credentials

From `agent-rust/`, run `cargo build --locked --release`, then:

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
```

Insecure/symlinked profile directories are refused, never silently made private.

## Backend launcher

The executable only hosts the backend; there is no CLI client, interactive terminal, or
chat/list/watch command. Options are `--profile PATH`, `--credentials PATH`,
`--workspace-tools`, `--host IP`, `--port PORT`, and the deliberate `--insecure-no-auth` opt-out.
The default profile is `~/.exec-agent`, and the default bind is **`127.0.0.1:8765`**.
`EXEC_AGENT_HOST` and `EXEC_AGENT_PORT` also configure binding; explicit flags take precedence.
Hosts must be numeric IP addresses. Loopback IPv4/IPv6, a specific interface, or a wildcard
are supported. Network exposure requires an explicit bind; IPv6 wildcard behavior is OS-dependent.
Invalid configuration fails startup, never falls back or selects another server.

The bundled macOS helper uses the same host/port configuration. The app generates fresh
API/native credentials for its child, unless an API token is explicitly supplied. A wildcard
bind maps to loopback for this local connection; external clients use the host's actual address.
An occupied port or unavailable interface fails startup. After binding and initialization,
the child writes only `ready\n`; this authenticates neither a server nor a caller, and clients
still must authenticate. There is no port scanning, endpoint discovery, or fallback server.
SIGINT/SIGTERM cancel and await work, checkpoint, release the listener and close the store.

## HTTP API v1: authentication and deployment

One HTTP/1.1 TCP server dispatches directly to the existing manager/runtime. There is no
Unix-socket alternative, proxy API, second runner, or production CLI/SDK implementation.

- **Default authentication:** set `EXEC_AGENT_TOKEN` to 32 cryptographically random bytes
  encoded as **64 hex characters**. Standalone startup without a valid token fails closed.
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
  data otherwise travel in plaintext. Swift supports HTTPS with normal certificate/hostname
  verification and never falls back to HTTP.
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
| POST | `/v1/conversations/:id/turns` | `{text,images?}` → `202 {operationID}` |
| POST | `/v1/conversations/:id/steer` | `{operationID,text}` → `202 {operationID,messageID}` |
| POST | `/v1/conversations/:id/cancel` | `{operationID}` → `202 {accepted:true,operationID}` |
| POST | `/v1/conversations/:id/approvals` | `{operationID,approvalID,approved:boolean}` → `{resolved:true}` |

Missing conversations return 404; invalid requests 400; busy/storage-blocked submissions and stale approvals/cancellations 409. Approval decisions are single use, including races. Cancellation acceptance is not cleanup completion; the acknowledgement echoes the exact operation accepted for cancellation.

A snapshot has `id`, `model`, `workspace`, `configuration`, `messages`, `pendingInput`, `metadata`, `usage`, `contextUsage`, `resources`, `operation`, `approval`, `activeToolCallID`, and `storageError`. Nullable fields are serialized explicitly as null. Operation states are `running`, `awaiting_approval`, `cancelling`, `completed`, `failed`, `interrupted`. Messages retain the original user/assistant/tool tagged JSON shapes, assistant completion status, finalized calls and paired tool outcomes. Rust declarations are in `src/core/types.rs`; command validation is in `src/service.rs`.

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
The API has no client authentication; prompts/project instructions are exposed to reachable HTTP
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
curl http://127.0.0.1:8765/v1/health
curl --no-buffer http://127.0.0.1:8765/v1/conversations/CONVERSATION_ID/events
```

## Shutdown and recovery

`service.close().await` stops accepting connections, disconnects observers/partial requests, settles catalog mutations, cancels runs, awaits cooperative provider/tool cleanup and final checkpoints, then closes the manager/store. Noncooperative adapters can delay shutdown. Normal shutdown releases the TCP listener and removes the store lock. Forced termination is not a clean tool shutdown.

Crash recovery never resumes work or steals ownership. Verify the old host and its tool processes have stopped, then explicitly remove only the stale `conversations/.lock` for that profile. See [README.md](README.md#persistence-and-recovery) for interrupted intent, missing results and possible side effects.

Tests cover these contracts with fake providers/transports and real network-bound TCP connections/subprocesses. Live OpenAI/DeepSeek, Linux deployment, browser OAuth, native OS permission behavior and Swift UI integration are not claimed verified.

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
work or mutate the source. Shell/image resource references are shared until the last referencing fork is deleted; transient native permissions are never forked.

`GET/PUT /v1/library` owns shared `defaultModel` (nullable), new-session `settings`, and
`order` (up to 10,000 unique conversation UUIDs). Omitted creation model/settings use these
defaults; workspace remains explicit. Order IDs missing from the catalog are harmless and
ignored. Unlisted sessions follow in stable ID order. `library.json` is atomically saved in
the private conversation store. Failed library writes block library mutations/default-based
creation until reload; existing conversation execution is independent. Corrupt library data
fails startup rather than silently resetting preferences. Clients retain their own selected
session, drafts, windows and scroll state.


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
provider state or measurements. Version 1–3 records remain readable; writes use version 7.
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
rejects pending input/busy sessions and models without compaction support. Steering is for
turn operations, not manual maintenance operations.

The OpenAI provider supports manual compaction and automatic compaction at 95% of the
last completed measured context window. Before inference the runner prepares required
model metadata. Automatic compaction includes completed history/tool outcomes but excludes
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

## Image assets, inputs and generation

| Method | Path | Contract |
|---|---|---|
| POST | `/v1/conversations/:id/images` | `{name,base64}` → `201 ImageRef`; idle-only owned upload |
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
The macOS app generates a fresh native secret for its owned helper, or uses a deliberately
provisioned one for an external backend. The native header is sent only for native operations.

TCP does **not** provide process attestation or same-host guarantees. The native secret
explicitly trusts its holders to register adapters, report OS permission, enable/disable
sessions and return correlated captures. It is not per-frontend/multi-tenant isolation.
The adapter enforces actual OS permission and explicit user consent; a live channel and
separate per-conversation grant are still required. Fully trusted API administrators can
execute host tools: these credentials are not an OS sandbox against same-user code.

| Method | Path | Contract |
|---|---|---|
| POST | `/v1/native/events` | `{osScreenPermission:boolean}` → live NDJSON: `registered`, `request`, `cancelled`, `ping` |
| PUT | `/v1/native/permission` | `{frontendID,granted}`; update the registered frontend’s reported OS permission |
| POST | `/v1/native/results` | `{request:NativeRequest,result:NativePayload}`; exact, live, single-use correlation required |
| GET | `/v1/conversations/:id/desktop` | `{frontendID,enabled}`; initially disabled |
| PUT | `/v1/conversations/:id/desktop` | Explicitly bind/enable one frontend or disable; independent of auto approval |

The registration event supplies `frontendID`. `NativeRequest` is
`{id,frontendID,conversationID,operationID,callID,action:{target,windowID}}`.
Targets are `desktop`, `list_windows`, `window`; only `window` takes a positive `windowID`.
Window capture requires a prior successful enumeration through the same frontend/session.
Results are `{type:"windows",windows:[{id,title}]}`, `{type:"image",base64}` or
`{type:"failed"}`. Window lists are bounded to 256 unique positive IDs and 1024-byte titles.
Window results have typed `details:{type:"windows",windows}`. Titles/screens remain
untrusted evidence, not instructions. Failed native results expose no arbitrary frontend
error string.

Capture preparation binds the exact frontend/action without requesting OS access. The
runner then enforces its approval policy and checkpoints intent before sending the request.
Results must match every correlation field and the live registered frontend; stale, wrong-target,
duplicate or post-cancellation results return 409. A 60-second deadline, disabled/rebound
session permission, revoked OS permission, disconnect or cancellation invalidates the
request. Cancellation notifications are best-effort bounded transport messages; acceptance
of late results never depends on notification delivery. No request is replayed or rerouted.
The native adapter must cancel its own capture work when notified or disconnected.

OS permission reports are claims from explicitly authorized adapters; the backend cannot
verify macOS TCC on behalf of Swift and never grants it. Reporting OS permission restored
does not re-enable session access. Native permissions/channels are transient, never restored
or forked. General observer disconnects still only detach; disconnecting the bound native
capability channel specifically revokes that capability and invalidates its pending calls.
The macOS app
implements the local adapter and explicit `/screenshots` session grant; see
`docs/swift-rust-migration.md` for its permission flow and verification limits. There is no
headless capture substitute.

### Automatic session titles

Library configuration includes `automaticTitles` (default `true`, including older saved configurations). At acceptance of each new user turn the manager applies this preference. The runtime runs isolated, tool-free title inference with the session model before chat inference, bounded to 15 seconds and cancellable with the operation. Failures retain the existing title without retry. Manual rename persists `manuallyNamed` and permanently suppresses automatic naming, including after restart. Naming shares operation ownership and checkpoints; it never appends to chat context. Setting changes apply to subsequent turns, not already accepted operations.

