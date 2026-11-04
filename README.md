# Harness

A small native macOS chat harness. SwiftUI, Foundation, Security, Network and CryptoKit only. No Codex executable, Node runtime, agent framework or third-party dependencies.

## Run

Requires macOS 14+ and a Swift 6 toolchain (Xcode or Apple Command Line Tools).

```sh
./scripts/build-app.sh
open dist/Harness.app
```

Quit an already-running copy before reopening the rebuilt app. Choose **Connect to Codex**, sign in in your default browser, select your authorized ChatGPT workspace, select an available model, and send a message. OpenAI still enforces your account's Codex access and usage limits. This app does not fall back to API-key billing or another authentication flow.

- **⌘Return:** send.
- **Stop:** cancel sign-in or the current request.
- **New:** clear the conversation once the current operation ends.
- **Account menu:** refresh the model list, reconnect or sign out. Sign out before changing ChatGPT accounts/organizations.
- Failed/stopped replies remain visible and are labeled as excluded from follow-up context. Completed tool steps and interruption records remain in context so their effects aren't silently forgotten.

The callback requires local port **1455**. If another app is signing in on that port, finish or close that sign-in and retry. The app never terminates another listener or forwards callbacks to it.

Open `Package.swift` in Xcode if you prefer IDE development; the script is sufficient without Xcode. The app is not notarized for distribution.

### Interface

Account controls live at the bottom of the sidebar. Model and workspace controls sit beside the composer. User messages are right-aligned with a very faint neutral background; assistant replies are left-aligned, without repeated speaker labels.

- **⌘N** starts a conversation, **⌘Return** sends, **⌘.** stops, and **Escape** denies a pending tool approval. Approval is never the default Return action.
- Reading earlier messages pauses automatic scrolling; the down-arrow returns to the latest reply. Resizing and streamed Markdown use measured layouts rather than estimated row heights.
- Switching sessions preserves keyboard focus in the sidebar. Draft entry remains available during a reply, but is disabled while changing/restoring conversations.
- Closing with **Quit** asks before discarding an unsent draft or unsaved changes. Active operations are cancelled and their cleanup/checkpoint is awaited before quitting.

### Markdown

Assistant replies render native Markdown: headings, emphasis, inline/fenced code, lists, quotes, tables and links. Code blocks scroll horizontally and have a Copy button. Parsing runs off the UI actor and accepts unfinished streamed fences; unusually large or deeply nested output falls back to literal text. User messages and tool output remain literal.

HTML is inert text and images are alt text only—nothing is fetched automatically. Only HTTP(S) and mail links can be opened, by clicking. No WebView or third-party renderer is used. Wide/compact layouts, light/dark appearance, approval/error panels and the scroll-follow policy were checked using native views with isolated fixtures. Clipboard, full keyboard navigation and VoiceOver still need a manual check.

### Project workspaces

Click **Workspace…** beside the composer to select a project. Its folder name is shown there; hover for the full path. The adjacent menu provides workspace settings and Reveal in Finder. The selected path and root `AGENTS.md` are sent to the model with subsequent messages. Selecting a workspace also permits the model to read/search its files; tool results are sent back to the model. Select trusted projects and consider what sensitive data they contain.

- Only `<selected folder>/AGENTS.md` is loaded—not ancestor or nested instruction files. Missing instructions are allowed; unreadable, non-UTF-8, oversized (over 64 KiB), or symlinked instruction files are rejected without replacing the current workspace/chat.
- Instructions are a snapshot. **Workspace → Reload Instructions** loads changes explicitly.
- Changing, closing, or reloading a workspace starts a fresh conversation and clears the draft, with confirmation if either contains content. **New** keeps the current workspace and instructions.
- Selection is optional: without a workspace the app remains a normal chat. The current workspace selection, instruction snapshot, and conversation are restored across app restarts.
- The built-in file tools enforce workspace-relative paths and refuse symlinks. This is not an OS sandbox. Shell commands have normal user access and require separate approval.

### Coding tools and approval

With a workspace selected, the model can use:

- **`list_files`**: one directory at a time; at most 2,000 entries / 32 KiB of output.
- **`read_file`**: UTF-8 text, line-numbered ranges of up to 400 lines, files up to 1 MiB, output up to 32 KiB. Includes a full-file content revision for edits.
- **`search_text`**: case-sensitive literal search, bounded to 2,000 visited entries, 100 matches, 16 directory levels, 32 KiB of output and a five-second scan budget. Hidden entries, `node_modules`, `dist`, symlinks, oversized and non-text files are skipped. Filesystem calls themselves may still wait on a slow volume.
- **`edit_file`**: proposes one exact, unique text replacement in a workspace file and shows the complete unified diff for approval (up to 64 KiB). It requires the revision returned by `read_file`; stale revisions are rejected. New files use revision `new` and empty `old_text`; their parent directory must already exist. Arguments must fit in 32 KiB; split larger changes. No fuzzy patching, file deletion, or implicit approval.
- **`shell`**: displays the exact command and working directory for **Approve Once** or **Deny**. Runs `/bin/bash --noprofile --norc` with a minimal environment, no interactive stdin, a 30-second timeout and 32 KiB of combined stdout/stderr. The app's inherited environment and OAuth tokens are not passed to commands.

**Shell approval is not a sandbox:** commands can read/write outside the workspace, access the network, or delete data. There is no automatic approval or command allowlist. Read-only inspection needs no per-call approval. Each edit and shell command requires its own approval.

Edits are checked again after approval and staged beside the target for atomic replacement. Existing ownership, mode bits, ACLs and extended attributes are preserved; inability to preserve them aborts the edit. New files are owner-readable/writable. Symlinks and special files are refused, and new-file creation never overwrites an existing path. Content/identity checks reject changes observed before replacement, but this is not a filesystem-wide compare-and-swap lock: an unrelated writer can still race the final check/rename. Avoid concurrent edits to the same file.

Tool calls execute sequentially, only after the model response completes. Each user turn is limited to eight model requests and sixteen executed tool calls. Expand a tool result in the conversation to see its arguments and output.

**Stop** cancels requests and pending approvals and sends termination to the shell process group, including ordinary child processes. It also cleans up ordinary background jobs after command exit. This is not containment: deliberately detached or privilege-elevated processes may escape that group. Commands may have changed files before cancellation or timeout; nothing is rolled back. Completed model/tool steps and interrupted-call records remain in the current conversation even if a subsequent model request fails. There are no automatic execution retries. Session checkpoints preserve tool outcomes and record interrupted operations on restart.

### Session persistence

The **Sessions** sidebar lists saved conversations for the connected account, ordered by the last user-message time. Opening a conversation does not move it in the list. New checkpoints also store the activity timestamp in the snapshot so index recovery preserves it. Select a conversation to restore it; use its trash button or context menu to delete it after confirmation. Switching and deleting are disabled during active requests/tools. **New** (⌘N) keeps earlier conversations and the selected workspace.

Harness stores one `<UUID>.json` snapshot per conversation plus a small `index.json` in `~/Library/Application Support/Harness/`. The previous single-file `session.json` is imported without changing message IDs or provider context. The index can be rebuilt from snapshots after an interrupted write; deleting a session removes its snapshot, so a stale index cannot bring it back. It restores the conversation, workspace/instruction snapshot, last checkpointed model selection, tool results, and provider-owned opaque response context. It never resumes model requests, approvals, or commands automatically.

- Checkpoints are atomic and run off the UI actor, before requests/tool execution and after tool outcomes. If saving fails, the agent stops rather than continuing with unrecorded actions.
- On restart, unfinished replies are marked interrupted and excluded from model context. Unresolved tool calls receive interruption records. An operation may have taken effect before its result was saved; inspect the workspace before retrying.
- Checkpoints occur at operation boundaries, not every streamed token. A force quit may lose partial text; unsent drafts are not saved.
- **New** and workspace changes preserve earlier saved conversations. Unsent drafts and changes that failed to save require confirmation before discarding. Empty chats without a workspace are not added to the sidebar. Sign-out clears the visible conversation/workspace, not the local archive; reconnect to the same account to see it again.
- Corrupt/incompatible saves are not silently overwritten. Open another session or choose **New**, and explicitly delete unreadable sessions if desired. Conversations are bound to the Codex account/workspace identity and cannot be restored into another account. Deletion removes the local save, not any files changed by tools; it is not a secure erase or server-side deletion.
- The session directory uses mode `0700` and snapshots `0600`. Chat text, code, tool arguments/results and instructions are stored locally **without application-level encryption** and may contain sensitive data. Managed authentication credentials remain in Keychain; conversation/tool content is not automatically redacted. Use FileVault if you need encrypted storage.

Each session snapshot is limited to 32 MiB; start a new conversation if it grows too large. Use one app instance at a time. These checkpoints do not provide a multi-file transaction, undo system, or recovery of shell processes that deliberately escaped their process group.

### Stable signing and Keychain prompts

By default, local builds use ad-hoc signing and print a warning: a rebuild can change the identity Keychain recognizes. To use a stable certificate:

1. Create an **Apple Development** signing certificate in Xcode → Settings → Accounts → Manage Certificates, or import an existing code-signing certificate and its private key into your login keychain.
2. List available identities: `security find-identity -v -p codesigning`.
3. Pin the chosen certificate locally (this configuration is not committed):

```sh
git config --local harness.signingIdentity "<certificate SHA-1>"
REQUIRE_STABLE_SIGNING=1 ./scripts/build-app.sh
```

For a one-off override, set `SIGNING_IDENTITY` to the certificate name or SHA-1. The build keeps the same bundle identifier and enables hardened runtime for certificate-signed builds. It verifies the signature and never falls back to ad-hoc signing after a configured certificate fails. `REQUIRE_STABLE_SIGNING=1` rejects an unconfigured/ad-hoc build before compilation.

A locally trusted self-signed code-signing certificate also works for development without Xcode or an Apple Developer subscription. This workspace is configured locally to use **Harness Local Development**, a five-year certificate in the login Keychain, trusted only for code signing in the user domain. The private key stays in Keychain; no certificate/key files or machine-specific signing configuration are committed.

Builds are signed and verified in a staging bundle before publication. They do not overwrite a running executable in place, which can otherwise cause macOS to terminate it for an invalid code-signature page. Quit and reopen to use the new build.

The signed app's designated requirement is tied to the bundle identifier and certificate, not a changing binary hash. Keep using the same certificate across builds. The switch from ad-hoc signing may require one more Keychain approval—choose **Always Allow** if you trust this app. Locked keychains or changed permissions can still prompt. Startup reads Keychain off the UI thread so a system permission prompt does not freeze the window. Permission must still be approved or denied by the user; access controls are not relaxed.

Self-signed builds are for this Mac; they do not provide Apple Developer ID trust or notarization for distribution. You can inspect the current signing requirement with `codesign -d -r- dist/Harness.app`.

## Structure

```text
Sources/Harness/
  App/                SwiftUI and observable conversation state
  Core/               Provider/tool interfaces, workspace file access, approval and shell execution
  Providers/OpenAI/   Codex OAuth, identity verification and Responses transport
  Storage/            Keychain credentials and atomic conversation checkpoints
```

`ChatStore` depends only on `ChatProvider`. To add a provider, implement that protocol and inject it in `HarnessApp`. Authentication, model discovery, connection-button text, wire formats, and opaque conversation data belong to the provider. There is no provider registry, plugin system, or generic OAuth layer.

## Connection

Uses the direct Codex protocol used by Pi's `openai-codex` provider:

1. Start a loopback-only listener and open OpenAI's `/oauth/authorize` browser flow with PKCE, state and nonce.
2. Exchange the authorization code at `/oauth/token` with the same `http://localhost:1455/auth/callback` URI.
3. Verify the ID token's signature and identity claims. Read the account ID used for Codex request routing.
4. Store this app's session in Keychain and serialize rotating refreshes.
5. Fetch the Codex model catalog using the separately pinned Codex compatibility version (`0.162.1`), not Harness's app version. Stream requests to `https://chatgpt.com/backend-api/codex/responses` with the account header, `store: false` and `stream: true`.

The app identifies itself as `swift_harness` in the originator header. It doesn't run Pi or Codex, read their credential files, or reuse the previous dynamic-registration connection's credentials. Its Keychain account is `openai.codex.session`; any old `openai.registration` record remains untouched and unused.

Sign-out attempts remote revocation before deleting local credentials, including when offline. If revocation cannot be confirmed, the app reports that explicitly. A failed Keychain deletion is reported rather than claiming successful local sign-out. Credentials and authorization URLs are not logged.

Refreshes are shared and not automatically retried. Before a rotating-token exchange, a marker is saved so a crash or lost response cannot replay the old refresh token on restart. An uncertain exchange requires **Reconnect**. If newly rotated tokens cannot be saved, they remain in memory and only the Keychain write is retried; unlock Keychain and retry before quitting.

API requests use an ephemeral URLSession with no shared cookies or disk cache, a 60-second inactivity timeout and a 10-minute resource timeout. Stop cancels the active stream/request. Authentication, permission, rate-limit and network errors have actionable messages; failed model discovery can be retried with **Refresh models** without browser sign-in.

This is a Codex-compatible backend integration, not the public API-key Responses API contract. Provider changes may require updates. Successful local builds/tests do not establish subscription eligibility or successful sign-in.

Network/SSE processing runs off the main actor. UI text updates are batched. Only completed turns enter follow-up context; partial/failed replies stay visible but are not sent back. Opaque Responses output, including encrypted reasoning, is preserved for follow-up turns.

## Tests

```sh
./scripts/test.sh
```

The dependency-free runner works with Command Line Tools alone. The focused checks cover workspace instruction loading/context isolation, authentication/identity validation, refresh and restart, token-rotation failures, offline sign-out, opaque follow-up/tool context, workspace boundaries, shell approval/process cancellation, approved edits/stale-file rejection, session recovery/checkpoint failures, SSE errors and cancellation. The added lifecycle checks use an in-memory credential store and an intercepted URLSession—not the user's Keychain or live model calls.

The user has verified live sign-in and messaging. Automated lifecycle checks are not a substitute for these final manual checks:

- Choose a folder, verify the displayed path, and cancel a workspace-change confirmation to keep the current chat.
- In a disposable project, ask the model to inspect a file and search for a symbol, then approve/deny harmless shell commands. Verify the actual approval UI and live Codex tool behavior; protocol tests use a fake transport, not the service.
- Approve an edit in a disposable project; inspect the resulting diff. Modify the file while another edit is pending and verify approval rejects the stale edit.
- Create two sessions, switch between them, and verify their messages/workspaces remain separate. Delete one and relaunch: the other should remain, with its follow-up context intact.
- Quit during a pending approval or model response: verify interruption is reported and nothing executes on reopen. Native approval dialogs and live-service recovery still need manual validation.
- Send a contextual follow-up, stop a reply, then send again: only completed turns should be remembered.
- Disconnect the network during a reply: an error appears without committing a partial turn; reconnect and retry manually.
- Let the session expire and send again: refresh succeeds, or the app clearly asks to reconnect.
- Sign out: local credentials are removed; offline sign-out warns if revocation is unconfirmed.
- Rebuild with the same certificate and reopen: verify Keychain access remains stable.

No live sign-in, token rotation, revocation or inference is performed by the build or test scripts.

## Deliberate v1 limits

- One connected account and one active conversation at a time; no multi-instance coordination.
- No multi-file edit transactions or undo manager. Editing supports exact replacement and file creation, not file deletion or directory creation.
- No automatic request retries or context compaction; start a new conversation if context grows too large.
- No distribution signing or usage dashboard.

## Protocol references

- Pi 1.4.0's `@earendil-works/pi-ai`: `auth/oauth/openai-codex.js` and `api/openai-codex-responses.js`.
- [Codex browser authentication implementation](https://github.com/openai/codex/blob/main/codex-rs/login/src/server.rs)
- [Codex model catalog implementation](https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/endpoint/models.rs)
