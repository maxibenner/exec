# Local service and CLI

The service owns the existing `AgentManager`, provider, tools, approvals, and JSON persistence. Clients never run another agent loop. One operation runs per conversation; different conversations can run concurrently. The Swift app is not connected to this API yet.

## Startup boundary

The implemented host entry is `startPersistentService()` in `src/service/persistent-service.ts`. It accepts an absolute profile directory and an already-configured `ChatProvider`. **There is not yet a credential-configured `serve` executable.** Credential loading and storage are unchanged: DeepSeek still accepts a host-supplied `getAPIKey(signal)` function. Do not put keys in CLI arguments, API requests, or conversation records.

Host integration, with a configured provider supplied by the embedding application:

```ts
import { startPersistentService } from "./src/service/persistent-service.ts";

const service = await startPersistentService({
  profile: absoluteProfileDirectory,
  provider: configuredProvider,
  workspaceTools: false, // Explicitly opt in to file/shell tools with true.
});

// A standalone host must install shutdown handlers. close() is idempotent.
const stop = () => {
  void service.close().catch(() => {
    console.error("Service shutdown failed. Inspect the profile before restarting.");
    process.exitCode = 1;
  });
};
process.once("SIGINT", stop);
process.once("SIGTERM", stop);
```

`configuredProvider` can be a `DeepSeekProvider` with the existing credential callback. These identifiers are supplied by your host; this snippet is an integration outline, not a runnable credential setup. There is no implicit model discovery or paid request during startup.

The host restores saved conversations but never resumes inference or actions automatically. Tools are a service-level opt-in applied to new and restored conversations; enabling tools is **not** a blanket approval. Read-only tools run without a prompt; edits and shell actions require individual approval. A different tool configuration on restart changes what future turns can use. Existing approvals are never restored.

The profile contains:

```
profile/                    owned directory, mode 0700
  service.sock              HTTP Unix socket, mode 0600
  conversations/
    .lock/                  single-owner store lock
    <conversation-id>.json  durable records, mode 0600
```

Keep the profile outside model workspaces. The full socket path must be at most 100 UTF-8 bytes. The CLI defaults to `~/.exec-agent/service.sock`; use a matching `--profile` for another host profile.

## CLI

Node 24+ is required. From `agent/`:

```sh
npm ci --ignore-scripts
npm run cli -- --help

# Once a provider-configured service host is running:
npm run cli -- health
npm run cli -- models
npm run cli -- new MODEL_ID /absolute/workspace
npm run cli -- chat CONVERSATION_ID
npm run cli -- list
npm run cli -- show CONVERSATION_ID
```

The `new` command prints the created conversation including its ID. Model discovery is explicit and may contact the provider. `chat` requires an interactive terminal, reopens the transcript, observes any active turn, then accepts messages. It displays the exact prepared approval description and workspace and accepts only `y` to approve; anything else denies. Model/tool output has terminal escape and bidi control characters escaped.

- Ctrl-C in `chat` or `send` requests cancellation of the current operation and waits for the terminal result; idle Ctrl-C exits.
- `/quit` at the chat input or EOF detaches the CLI. Detachment is not cancellation.
- Ctrl-C in `watch` only detaches; it does not mutate the operation.
- Closing/killing a client does not kill the service. Work can continue, or remain awaiting approval.
- There are no automatic inference, approval, or transport retries. Reconnecting for observation never resubmits a prompt.

Scriptable commands:

```sh
npm run cli -- --profile /absolute/profile send CONVERSATION_ID "A message"
npm run cli -- --profile /absolute/profile watch CONVERSATION_ID
npm run cli -- --profile /absolute/profile cancel CONVERSATION_ID OPERATION_ID
npm run cli -- --profile /absolute/profile approve CONVERSATION_ID OPERATION_ID APPROVAL_ID
npm run cli -- --profile /absolute/profile deny CONVERSATION_ID OPERATION_ID APPROVAL_ID
```

`send` follows the submitted operation until it becomes terminal and exits nonzero for failure/interruption. It never approves tools automatically. If approval is pending, use a second CLI/client with the exact IDs printed with the approval. `watch` continues observing across turns. CLI failures do not imply the server did nothing: inspect `show`/`watch` before deciding what to do next. Only the latest operation is retained in the snapshot; if another client starts a new operation before `send` attaches, `send` reports that change instead of following the wrong turn.

## API v1

HTTP/1.1 over the profile's Unix socket. No TCP port, cookies, CORS, or remote authentication. Browsers' Origin/Fetch-Metadata requests are rejected. Any process running as the owning user is trusted; this is not a boundary against malicious same-user tools or a hostile filesystem. **Do not forward this socket through a public/network proxy.** Authenticated remote access is a separate feature.

Bodies use `Content-Type: application/json`, with no unknown fields. Requests are bounded to 256 KiB, message text to 128 Ki UTF-16 code units, and workspace paths to 4,096 code units. Workspaces must be existing absolute directories and are canonicalized. Approval/cancellation identifiers are UUIDs. Errors use an HTTP status and `{ "error": "safe message" }`, never raw provider exceptions. Oversized/interrupted bodies can also cause a connection reset.

| Method | Path | Body / result |
|---|---|---|
| GET | `/v1/health` | `{ version: 1, toolsEnabled: boolean }` |
| GET | `/v1/models` | Neutral `ChatModel[]`; explicit provider discovery |
| GET | `/v1/conversations` | Summary array: ID, model, workspace, latest operation, storage error; no messages/approval descriptions |
| POST | `/v1/conversations` | `{ model, workspace }` → `201 ConversationSnapshot`, after durable creation |
| GET | `/v1/conversations/:id` | `ConversationSnapshot` |
| GET | `/v1/conversations/:id/events` | Live NDJSON, described below |
| POST | `/v1/conversations/:id/turns` | `{ text }` → `202 { operationID }` |
| POST | `/v1/conversations/:id/cancel` | `{ operationID }` → `202 { cancelled: true }` |
| POST | `/v1/conversations/:id/approvals` | `{ operationID, approvalID, approved: boolean }` → `{ resolved: true }` |

Missing conversations return 404; invalid requests 400; busy/storage-blocked submissions and stale approvals/cancellations 409. Cancellation acceptance is not completion; observe the terminal operation. Approvals resolve exactly once, including when clients race.

**Turn acceptance is in-memory, not a durable receipt.** The runtime persists the input before inference, but a `202` may precede that checkpoint. A lost response can also happen after inference or tools started. No idempotent submission/replay mechanism is advertised: reconnect, inspect the snapshot, and make an explicit decision. Terminal success is emitted only after its final checkpoint succeeds. Intermediate streaming snapshots are not durability acknowledgments.

Example inspection without the CLI:

```sh
curl --unix-socket "$HOME/.exec-agent/service.sock" http://localhost/v1/health
curl --no-buffer --unix-socket "$HOME/.exec-agent/service.sock" \
  http://localhost/v1/conversations/CONVERSATION_ID/events
```

### Streaming contract

`Content-Type: application/x-ndjson`: each UTF-8 line is one JSON object, not SSE. Shared types live in `src/service/protocol.ts` and `src/core/types.ts`.

1. The first frame is `{ type: "snapshot", snapshot: ConversationSnapshot }`.
2. Subsequent frames are `{ type: "runtime", event: RuntimeEvent, snapshot?: ConversationSnapshot }`.
3. Text events contain `messageID` and `delta`; append that delta to that message's text.
4. Non-text events carry a complete snapshot; replace/reconcile state, do not append its transcript again.

The subscription and initial snapshot are established synchronously, with no update gap. There is no event replay buffer, cursor, heartbeat, or automatic reconnect. A new connection always starts from the current snapshot, including any pending approval. Streams remain open after a terminal operation to observe future turns. Slow observers are disconnected when the queued response exceeds 1 MiB before the next frame; one frame can be larger than that threshold. This cannot block inference or trigger a retry. Clients bound individual responses/frames to 32 MiB and must explicitly reconnect after interruption.

The Node `AgentClient` exposes `create`, `list`, `get`, `submit`, `cancel`, `approve`, `models`, `health`, and `events`. It performs no retries or redirects. Its public `call` method supports direct versioned requests without provider-specific types.

## Shutdown and recovery

`await service.close()` stops accepting connections, disconnects observers/partial requests, settles accepted catalog requests, cancels active operations, waits for provider/tool cleanup and final checkpoints, then closes the manager/store. Providers/tools must cooperate with cancellation; an uncooperative adapter can delay shutdown. The service never claims that a forced process kill cleanly stopped tools.

Normal shutdown removes the socket and releases the store lock. Abrupt termination may leave both the socket and `conversations/.lock`. Neither is automatically removed or stolen on startup. Verify the old host **and its tool processes** have stopped, then explicitly remove only that profile's stale socket and lock. See [persistence/recovery](README.md#persistence-and-recovery) for interrupted execution intent and possible side effects.

## Verification

Automated tests use real Unix sockets and separate CLI subprocesses with fake providers, isolated stores, and temporary workspaces. They cover durable reopening, concurrent operations, exact approvals, cancellation, disconnect semantics, safe errors, and lost-response no-retry behavior. They do not verify live DeepSeek, credential loading, interactive TTY behavior, Linux deployment, remote access, or a connected Swift UI.
