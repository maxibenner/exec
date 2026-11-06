# Exec

A native macOS chat and coding app for Codex. Built in Swift with SwiftUI and Apple's system frameworks—no Codex executable, Node runtime, agent framework, or third-party dependencies.

- Stream replies with selectable Markdown, code blocks, tables, and links.
- Search the web through your existing Codex login, with saved queries and clickable sources.
- Drag images into the composer, review thumbnails, and send them with or without text.
- Run several conversations at once, each with its own draft, model effort, workspace, context, and approvals.
- Inspect project files, approve exact edits, and review responsive inline diffs.
- Save conversations locally and compact model context automatically near its limit.

Exec uses your ChatGPT/Codex sign-in, not API-key billing. Account eligibility and usage limits are enforced by OpenAI. This is a Codex-compatible backend integration, not the public Responses API contract; provider changes may require updates.

## Build and run

Requires **macOS 14+** and a **Swift 6 toolchain** (Xcode or Apple Command Line Tools).

```sh
./scripts/build-app.sh
open dist/Exec.app
```

Quit any running copy before reopening a rebuilt app. Choose **Connect to Codex**, complete sign-in in your browser, select your authorized ChatGPT workspace, and choose a model. The callback uses local port **1455**; finish any other sign-in using that port before retrying. Exec never terminates another listener.

You can also open `Package.swift` in Xcode. Builds are not notarized for distribution. For consistent Keychain access across rebuilds, configure [stable signing](#signing-and-keychain) before building.

## Using Exec

### Conversations

| Action | Control |
| --- | --- |
| New conversation | **⌘N** or the toolbar button |
| Send (or queue while a reply is running) | **Return** |
| Stop the current operation | **Escape**, **⌘.**, or the animated indicator |
| Deny a pending tool approval | **Deny** button |
| Rename or delete a conversation | Sidebar row context menu |
| Refresh models, reconnect, or sign out | Account menu at the bottom of the sidebar |

Switching conversations does not stop background work. Each conversation keeps its own runner, model context, workspace, draft, approval queue, and auto-approval setting. Stop affects only the displayed conversation. Account changes are blocked while a turn is running.

The eight most recently visited conversations stay resident for immediate switching without loading or saving full snapshots. Older idle sessions unload automatically and reopen from their saved snapshot when selected. Running work, drafts, queued messages, pending saves, and unsaved changes are protected, so the resident count may temporarily exceed eight. There is no manual close action; deletion remains explicit.

Resident presentation state retains scroll position, expanded tool results, measured heights, and a bounded parsed-Markdown cache; inactive transcripts unmount their views while their runners continue. Rapid selections supersede an unfinished archive load. Reading positions and expanded-tool state are kept in memory and reset when a session is evicted or the app quits.

The transcript mounts only visible messages and a small buffer. Inactive conversations retain scroll anchors and lightweight presentation data, without hidden view trees. Reading earlier messages pauses automatic scrolling. Use the down-arrow to return to the latest reply. Quit asks before discarding drafts or unsaved changes, cancels operations across all conversations, and waits for their cleanup and checkpoints.

Messages submitted during an active turn queue inside that conversation's composer. Use **×** to remove an unsent item. Queued text and attachments run in order only after the preceding turn completes and saves successfully, including while the conversation is in the background. Stop, provider errors, and checkpoint failures pause the queue; use its **play** button to resume explicitly. Queued messages, like drafts, are kept only in memory and are included in the quit warning.

### Composer commands and usage

Type `/` at the start of a message to open the command menu above the input. `/model`, `/reasoning` (alias `/effort`), and `/auto-approve` (aliases `/approve`, `/approval`) select their settings. Prefixes such as `/r` filter the menu. Arrow keys navigate, Return selects, and Escape dismisses the menu before stopping a turn. `/compact` compacts completed context immediately, without waiting for the automatic threshold. It is available when the conversation is idle and has completed history; visible messages remain intact. Stop cancels it, and failures are not retried. These commands are handled locally, not sent as messages.

Model, reasoning, and approval state are non-clickable labels inside the input. Reasoning choices come from the selected model's Codex catalog entry. **Default** leaves the choice to the provider; the catalog's default level is shown when available. Model and reasoning selections are checkpointed per conversation; new conversations inherit the supported setting. Both are locked during an active turn. Auto-approval defaults to on for new and reopened workspace conversations. Selecting `/auto-approve` toggles it directly; there is no submenu. The setting stays scoped to each resident conversation.

The footer shows workspace, context usage, and available account-limit percentages reported by Codex. Account usage is separate from context size; it refreshes after account operations and conversation activity, and expired or unavailable readings are hidden. The provider integration follows [Codex's usage endpoint](https://raw.githubusercontent.com/openai/codex/main/codex-rs/backend-client/src/client/rate_limit_resets.rs); live usage availability still needs manual verification. The animated working indicator reproduces the eight-cell, 80 ms bounce from `../pi-config` and respects Reduce Motion.

### Images

Drag image files or image data into the message composer. Thumbnails appear above the text field; use a thumbnail's **×** button to remove it before sending. Text is optional.

- Up to **four images per message**, totaling **8 MiB after resizing**.
- Source files must be at most **20 MiB**, with at most 100 megapixels and neither dimension over 32,768 pixels. Animated and multi-image sources are rejected.
- Images are decoded with ImageIO, orientation-corrected, and resized to a maximum edge of **2,048 pixels**. The prepared image must fit within 4 MiB.
- Images are re-encoded as JPEG, or PNG when transparency is present. Original file metadata is not copied.
- Dropping a web link does not download its target. A drop containing an invalid image fails without attaching the rest of that batch.
- Pending imports and unsent attachments stay with their original conversation when you switch sessions. Sending waits until the import finishes.

Sent images are copied into the local conversation snapshot and included in model context; deleting or moving the original file does not break them. Unsent text and images are kept only in memory. Image understanding depends on the selected model and backend support; live Codex image requests still need manual validation.

### Replies and diffs

Assistant replies render headings, emphasis, code, lists, quotes, tables, and links. Code blocks have horizontal scrolling and a Copy button. Links use native selectable TextKit text with pointing-hand cursors. User text and ordinary tool output remain literal.

Successful `edit_file` results include collapsible diffs: side-by-side with line numbers in wide layouts, unified in narrow layouts. Failed or uncertain edits are not shown as applied. Shell-driven changes do not generate automatic diffs.

HTML is inert. Images embedded in assistant Markdown remain alt text; they are not fetched automatically. Only HTTP(S) and mail links open on click. No WebView is used.

## Web search

Ask a question that needs current information, or explicitly ask Exec to search the web. The model can call **`web_search`** in ordinary chat or a project conversation; no workspace or additional API key is required.

Exec makes a separate request to Codex using its existing Keychain-managed login, the selected model, and the selected effort. The request includes OpenAI's hosted `web_search` tool and requires a search. Only the generated query is sent as input to this separate request—not the conversation history, images, or workspace instructions. The model is instructed not to include secrets or private project content in queries; review what you ask it to research.

- The query, search answer, and source links appear in an expandable result in the transcript. Sources use native selectable links and are saved with the conversation.
- Queries are limited to 2,048 UTF-8 bytes. Each result contains at most ten distinct HTTP(S) source URLs and a bounded answer, totaling no more than 32 KiB of model-facing text. This is not a full-page reader or a cached-content retrieval tool.
- Search results are untrusted evidence. The model is instructed to cite returned URLs and not claim to have searched without a successful result. A model-only answer without a hosted search call is rejected.
- Search uses your account's access and usage allowance. It does not require file/shell approval and does not fall back to API-key billing, Exa, or another provider.
- Stop cancels the active search. Failed, unsupported, or interrupted searches stop the turn without automatic retries. Search requests are never resumed after restart.
- Search output cannot replace the conversation's opaque response context. Only the completed, bounded tool result enters follow-up context.

The implementation follows the Codex-backed approach in [Pi Web Access](https://github.com/nicobailon/pi-web-access), but runs natively in Swift without Pi, Node, or an MCP sidecar. Hosted search availability depends on the selected model and account. **Live Codex search remains unverified**; transport tests use synthetic responses.

### Reading a page

The model can use **`fetch_content`** to read a specific public HTTPS URL, with or without a workspace. This is a direct website request: it returns extracted HTML text or plain text/JSON/XML, not a model-generated summary. The result, including its final URL, is saved in the conversation and passed back to the model.

- HTTPS on port 443 only, URLs up to 2,048 UTF-8 bytes, no embedded credentials. Website requests use an isolated ephemeral session without cookies, cached responses, saved credentials, or Codex authorization.
- Each request has a 30-second resource timeout. Up to three redirects are followed, checking each URL and its resolved addresses before requesting it. Local, private, and reserved addresses are rejected in this preflight. This is **not a network sandbox or DNS-pinning guarantee**: the system HTTP client resolves names again when connecting. Normal TLS certificate validation remains enabled.
- Redirects to ordinary HTTP URLs (no port or port 80) are upgraded to HTTPS on port 443 before validation and fetching, preserving the host, path, and query. Other HTTP ports are rejected. HTTPS failures never fall back to plaintext HTTP; redirect limits and destination checks still apply.
- Downloads are limited to 1 MiB; returned page text is limited to approximately 24,000 UTF-8 bytes with an explicit truncation marker. JavaScript, authenticated pages, PDFs, and other binary documents are not supported. HTML extraction is intentionally simple and can include navigation or other non-article text.
- Page text is untrusted evidence, not instructions. Do not put secrets in URLs. Stop cancels the fetch; failures stop the turn and are not automatically retried or resumed after restart.

Automated checks use fake HTTP responses and isolated session stores, not live websites or the user's credentials. Live-site extraction and UI behavior still require manual verification.

## Working on a project

Choose **Workspace…** beside the composer. The selected path and a snapshot of its root `AGENTS.md` are sent to the model, along with requested file contents and tool results. Choose trusted projects and consider what sensitive data they contain.

Only `<workspace>/AGENTS.md` is loaded—not ancestor or nested instruction files. Missing instructions are allowed; unreadable, non-UTF-8, symlinked, or oversized files (over 64 KiB) are rejected. **Workspace → Reload Instructions** explicitly reloads them.

Changing, closing, or reloading a workspace starts another conversation, with confirmation when appropriate. The previous conversation and its in-memory draft remain available. **New** keeps the selected workspace and instruction snapshot. A workspace is optional for ordinary chat.

### Tools

| Tool | Behavior |
| --- | --- |
| `list_files` | Lists one directory; bounded to 2,000 entries and 32 KiB of output. |
| `read_file` | Reads line-numbered UTF-8 text and returns a revision for editing. Up to 400 lines, 1 MiB files, and 32 KiB of output. |
| `search_text` | Case-sensitive literal search with bounded traversal, time, and output. Skips symlinks, non-text/oversized files, hidden entries, `node_modules`, and `dist`. |
| `edit_file` | Proposes an exact, unique replacement against a known revision, or creates a new file. Shows the complete proposed diff for approval. Rejects stale revisions; no fuzzy patching or file deletion. |
| `shell` | Runs the displayed command with `/bin/bash --noprofile --norc`, a minimal environment, no interactive stdin, a 30-second timeout, and 32 KiB of combined output. |

`read_file` already accepts inclusive, one-based line ranges. For example:

```json
{"path":"Sources/Exec/App/ChatStore.swift","start_line":120,"end_line":200}
```

Use `search_text` to locate relevant lines, then read the surrounding range. Only the requested lines enter model context. The reader still reads the bounded full file locally to validate UTF-8 and compute the full-file revision used for safe edits.

Read-only tools do not require per-call approval. Edits and shell commands require **Approve Once** when auto-approval is off. Approval is never the default Return action. App credentials and the inherited environment are not passed to shell commands.

**Auto-approve** defaults to on for workspace conversations and is toggled directly through `/auto-approve`. It applies only to that conversation, including its background work. A toggle is not transferred to other resident conversations or saved across restarts; newly opened workspace conversations start on. It does not bypass path, revision, checkpoint, or cancellation checks. Turning it off affects future approvals; use Stop to cancel current work.

### Safety boundaries

**Shell approval is not a sandbox.** Commands run with your normal user access: they can reach outside the workspace, use the network, and delete data. The built-in file tools enforce workspace-relative paths and refuse symlinks, but those restrictions do not constrain shell commands.

Edits are checked again after approval and staged for atomic replacement. Existing ownership, mode bits, ACLs, and extended attributes are preserved; failure to preserve them aborts the edit. New files are owner-readable/writable and never overwrite an existing path. File replacements within Exec are serialized, but external writers can still race the final filesystem operation. Avoid concurrent edits to the same file.

Tool calls run sequentially within each conversation, only after a completed model response. A turn can continue through many model/tool steps until it finishes, fails, or is stopped; there is no fixed eight-step cap. Monitor usage during auto-approved runs.

Stop cancels model requests and approvals and terminates the shell process group, including ordinary child processes. Deliberately detached or privilege-elevated processes may escape that group. Cancellation does not undo changes. Failed replies remain visible but are excluded from follow-up context; completed tool steps and interruption records remain so their effects are not forgotten. **Inference, compaction, rotating-token exchanges, and tool execution are not automatically retried.**

## Local storage and recovery

Exec was previously named Harness. The legacy Application Support directory and `local.swift-harness` bundle/Keychain identifier intentionally remain unchanged so existing chats, credentials, and signing identity continue to work. Quit the old app before opening Exec; do not run both against the shared store.

Conversations are stored in:

```text
~/Library/Application Support/Harness/
  index.json
  <conversation-UUID>.json
```

Snapshots contain the transcript, sent images, workspace instructions, tool outcomes, last checkpointed model and effort selections, and provider-owned response context. Credentials stay in Keychain. The directory uses mode `0700` and snapshots `0600`, but conversation data has **no application-level encryption** or automatic secret redaction. Use FileVault if you need encrypted storage.

- Checkpoints are atomic and run off the UI actor, before requests/tool execution and after tool outcomes. A failed checkpoint stops further work rather than allowing unrecorded actions.
- On restart, unfinished replies are marked interrupted. Unresolved tool calls receive interruption records; requests, commands, and approvals are never resumed automatically.
- Checkpoints occur at operation boundaries, not every streamed token. A force quit can lose partial text. **Unsent drafts and attachments are not persisted.**
- Corrupt or incompatible saves are not silently overwritten. The index can be rebuilt from snapshots, and the older single-file `session.json` format is imported.
- Conversations are isolated by Codex account/workspace identity. Sign-out clears the visible conversation, not the archive; reconnect to the same identity to see it again.
- Deletion removes the local snapshot, not files changed by tools or server-side data. It is not a secure erase.

Each snapshot is limited to **32 MiB**. Image data is base64-encoded in both the transcript and completed history, so image-heavy conversations can reach this limit quickly. Start a new conversation if saving fails because of size. Use one app instance at a time; there is no multi-instance coordination or undo system.

### Context compaction

Before each model request, Exec checks usage against **95% of the selected model's usable context window**. It prefers server-reported input/output usage, estimates newly added text, and budgets images separately rather than counting base64 bytes as text tokens. These estimates are not an exact tokenizer. Missing model-limit metadata stops the request and asks you to refresh models.

At the threshold, or when `/compact` is selected in an idle conversation, Codex's `/responses/compact` endpoint compacts completed history. Pending input and unresolved tool calls are not summarized. The returned opaque context is checkpointed before inference continues. The visible transcript, images, diffs, and tool outcomes remain intact: **compaction reduces model context, not local archive size**.

Failed or cancelled compaction keeps the original context and stops the turn without an automatic retry. Summarization is lossy, and very large inputs can still exceed server limits. Live Codex compaction remains unverified.

## Signing and Keychain

Unconfigured builds use ad-hoc signing and print a warning. Rebuilding can then change the identity Keychain recognizes. To use stable signing:

1. Create an Apple Development certificate in Xcode, import an existing code-signing identity, or create a locally trusted development certificate.
2. List available identities with `security find-identity -v -p codesigning`.
3. Pin one locally:

```sh
git config --local exec.signingIdentity "<certificate SHA-1>"
REQUIRE_STABLE_SIGNING=1 ./scripts/build-app.sh
```

`SIGNING_IDENTITY` provides a one-build override. Signing configuration and private keys must not be committed. Builds use the same bundle identifier, enable hardened runtime for certificate-signed builds, and verify the staged bundle before publication. A configured signing failure never falls back to ad-hoc signing.

Keep using the same certificate. Switching from ad-hoc signing may require one more Keychain approval; choose **Always Allow** only if you trust the app. Locked keychains or changed permissions can still prompt. Startup Keychain reads run off the UI thread; access controls are never relaxed. Self-signed builds are for local development, not distribution trust or notarization.

## Development

```sh
./scripts/test.sh
./scripts/build-app.sh
```

The dependency-free test runner works with Command Line Tools alone. Tests use isolated session stores, in-memory credentials, fake providers, and intercepted HTTP—not your Keychain or live inference.

```text
Sources/Exec/
  App/                SwiftUI, image import, and observable conversation state
  Core/               Provider-neutral messages, attachments, tools, and workspace access
  Providers/OpenAI/   Codex authentication, model discovery, and Responses transport
  Storage/            Keychain credentials and atomic conversation checkpoints
Tests/ExecTests/   Focused regression checks and fake transports
```

`ChatLibrary` owns navigation and retains independent `ChatStore` runners. Both depend on `ChatProvider`; `makeConversationProvider()` shares authentication while isolating mutable response context. To add a provider, implement that protocol and inject it in `ExecApp`. Wire formats, authentication, model discovery, and opaque context stay in `Providers/`. Web search is an explicit provider capability; coding tools remain workspace-scoped. There is no plugin registry.

### Connection details

Exec uses browser OAuth with PKCE, state, nonce, and a loopback callback. It verifies ID-token signatures and claims, stores its own session in Keychain, fetches the model catalog, and streams directly from the Codex Responses endpoint with `store: false`. It does not run Pi or Codex or read their credential files. The separately pinned catalog compatibility version is `0.162.1`; the originator is `swift_exec`.

Refreshes are shared across conversations. Cancelling one caller does not cancel a rotating-token exchange needed by others. A durable pre-exchange marker prevents replay after an uncertain outcome; such a failure requires Reconnect. If rotated tokens cannot be saved, only their Keychain write can be retried—not the exchange.

Sign-out attempts remote revocation and local credential deletion, including offline. Unconfirmed revocation and failed local deletion are reported separately. Authorization URLs, tokens, and account identifiers are not logged. Requests use an ephemeral URLSession without shared cookies or disk cache, with a 60-second inactivity timeout and 10-minute resource timeout.

### Verification status

The automated checks cover authentication, refresh/restart safety, cancellation, session integrity, concurrent conversations, tool approval and edits, compaction, streaming, Markdown, diffs, image normalization, request encoding, attachment persistence, pending-drop conversation isolation, effort discovery, request encoding, and session isolation, plus web-search authentication routing, bounded sources, context separation, persistence, cancellation, and failure without retries. Run the full checks and signed build in the normal local environment; restricted environments may not expose macOS item-provider registration, Security-framework key generation, or the configured signing identity. Isolated native fixtures also render the image previews and effort controls at wide and narrow widths. These checks do not establish live-service behavior.

Live sign-in and text messaging were previously verified by the user. Remaining manual checks include:

- Drag images from Finder and another app into the actual input field; remove one, send an image-only message, and confirm the model can describe it. Switch conversations during an import, then relaunch after sending.
- Check sidebar selection with wrapping titles, light/dark appearance, keyboard navigation, clipboard behavior, and VoiceOver. Change effort levels with a live model and confirm the advertised options are accepted.
- In a disposable workspace, approve/deny edits and shell commands; verify stale-file rejection and rendered diffs.
- Open seven long conversations, including streaming turns, and rapidly switch between them. Check responsiveness, retained reading positions and expanded tools, and memory usage; then visit more than eight sessions and reopen an evicted one. Automated tests verify bounded native row mounting, pixel-anchor restoration, synchronous resident selection without snapshot rewrites, sidebar observation isolation, superseded loads, and durable recovery. Frame timing still requires a visible-app benchmark.
- Run concurrent live turns and confirm Stop, drafts, auto-approval, and pending approvals remain isolated. Rename a running session; delete an idle one and relaunch.
- Ask a public current-information question and confirm a real search returns working source links. Stop a search in flight, then reopen the conversation to verify its interruption record. Test an unsupported model/account without falling back to another service.
- Exercise live compaction, interrupted replies, network failure, token expiry, and offline sign-out. Confirm no operation resumes or retries automatically.
- Rebuild with the same certificate and check that Keychain access remains stable.

## References

- [Codex browser authentication](https://github.com/openai/codex/blob/main/codex-rs/login/src/server.rs)
- [Codex model catalog](https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/endpoint/models.rs)
- [Codex compaction contract](https://github.com/openai/codex/blob/rust-v0.100.0/codex-rs/codex-api/src/endpoint/compact.rs)
- [Responses compaction guide](https://developers.openai.com/api/docs/guides/compaction)
- [Responses image inputs](https://developers.openai.com/api/docs/guides/images-vision)
- [Responses hosted web search](https://developers.openai.com/api/docs/guides/tools-web-search) (public API documentation, not a Codex backend guarantee)
