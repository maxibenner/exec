# Backend parity implementation contract

## Agreed scope

Backend parity with the original Swift Exec application comes before Swift API integration.
Remote access, Keychain, Swift-store migration, and frontend implementation are excluded.
Credentials use environment variables or private JSON; JSON-backed authentication may
persist rotating tokens. Environment credentials take precedence and remain externally
managed. New sessions will default to auto-approval. Minimal, useful dependencies are
allowed. Screenshots require a connected Swift frontend; a headless service must not
capture its desktop or fall back to another capture mechanism. The eligible frontend
must be local to the backend host and explicitly enabled for desktop access; auto mode
cannot grant OS permission or enable that access. Window enumeration is equally gated.
Requests target one bound frontend; cancellation/disconnect invalidates late results,
with no retry or fallback. Swift owns capture and permission; the runner owns invocation,
approval enforcement and lifecycle; the manager owns capability registration and accepted
image assets; the API only transports correlated requests/results.

Automatic title generation and persisted before/after account allowance observations
are deferred. Keep prompt-derived/manual titles, current allowance/reset information and
balances. Selected session, drafts, scroll/window state and other presentation preferences
remain frontend-owned. Isolate unreadable conversations without silently discarding them;
fail closed for uncertain store ownership/integrity. Tool bounds need not match Swift's
exact byte counts, but truncation and full-log access must remain truthful.

This file describes the target and remaining work, not implemented capabilities.
README.md and API.md describe current behavior.
The checked items below are delivered and verified; unchecked items remain outstanding.

## Ownership

- **Runner:** one conversation's execution and authoritative operation state; provider
  steps, safe-boundary steering, context/compaction coordination, exact prepared-action
  approval enforcement, cancellation cleanup, and execution checkpoints. No HTTP,
  catalog orchestration, UI, or provider wire formats.
- **Manager:** conversation creation/configuration/catalog, durable mutations, provider
  and tool composition, titles, fork/delete, asset/log ownership, account services,
  and persistence coordination. No second inference loop.
- **Providers:** authentication, model discovery/capabilities, wire formats, account
  usage/balance, search/image services, and opaque per-conversation response context.
  Shared authentication must not share mutable conversation state.
- **Tools:** concrete preparation, validation, execution, and cleanup. Approval policy
  is enforced by the runner, not by a client or an independent tool loop.
- **API:** validated commands, neutral snapshots/events, assets and capability transport.
  Delegate behavior to manager/runner. Never interpret provider state or retry mutations.
- **Frontend:** drafts, rendering, navigation, native windows and permissions, shortcuts,
  presentation preferences, and optional native capture adapter. No authoritative
  transcript, inference loop, or independent approval policy. A native adapter result
  must be correlated to the exact live operation/action; disconnects must not cause
  replay. Implementing the Swift adapter itself is a later integration phase.

## Implementation checklist

### Delivered

- [x] Expose existing manager deletion via DELETE /v1/conversations/:id, typed client,
  and CLI; reject active operations and verify deletion survives restart.
- [x] Persisted session system prompt and auto-approval policy, default enabled for new
  sessions, with idle-only durable settings updates via manager/API/client/CLI.
- [x] Manager-owned safe root AGENTS.md loading at first accepted turn; durable frozen
  instruction snapshot, selected workspace and behavioral instructions in neutral requests.
- [x] Runner-owned automatic/manual authorization preserving preparation, validation,
  execution checkpoints and cancellation; old records retain manual approval.
- [x] Version-2 checkpoint configuration with conservative version-1 read support. No
  Swift-store import or claim of backwards writes to the TypeScript sketch.

- [x] Operation-targeted steering, checkpointed pending input, safe-boundary injection,
  approval withdrawal and explicit superseded results; restart never resumes input.

- [x] Session titles/manual naming, activity timestamps, idle model changes, forks,
  shared ordering and configurable new-session defaults through manager/API/client/CLI.

- [x] Credential-independent startup/history access and runtime DeepSeek API-key
  connect/disconnect via private JSON, provider-neutral status/API/client and stdin-only CLI.
  Environment values remain externally managed; no live validation is claimed.

- [x] Isolated unreadable-conversation summaries and explicit deletion; valid history
  stays available while unsafe store entries/ownership failures still fail closed.

- [x] Provider-neutral public search and balance services, DeepSeek implementations,
  web_search tool, API/client/CLI coverage, bounded source decoding, no retries, and
  stale account-observation protection after credential changes. Live service unverified.

- [x] Public HTTPS fetch tool/API/client/CLI with DNS-pinned public destinations,
  revalidated redirects, bounded UTF-8 text/HTML extraction, cancellation and no retries.

- [x] Provider-neutral effort/model metadata, persisted effort selection and token usage;
  DeepSeek thinking/default/off modes with opaque tool-continuation state checkpointed
  only after valid completion and restored per conversation. Opaque state is not in API snapshots.

- [x] Provider registry with namespaced model routing, isolated opaque provider contexts,
  discovery fallback warnings and credential-generation cache invalidation. Standalone
  currently registers DeepSeek; a second concrete provider (OpenAI) remains outstanding.

- [x] Managed private shell logs, bounded API/client/CLI reads, optional descriptive
  shell titles, execution-intent resource references and last-fork-aware deletion.
  Cleanup retains files conservatively when unreadable sessions may reference them.

### Remaining backend work

- [ ] Image-input capability integration (model metadata is available).
- [ ] OpenAI subscription provider, browser OAuth, safe token refresh/persistence,
  JSON credential management and runtime connect/disconnect.
- [ ] Provider/account model metadata caches.
- [ ] Manual/automatic compaction and context-window usage presentation metadata.
- [ ] Typed tool results, assets, image inputs and durable image references.
- [ ] Image generation and OpenAI search support.
- [ ] Optional frontend screenshot capability protocol, session permission, exact
  request/result correlation, cancellation/disconnect handling; no headless capture.
- [ ] Typed applied-edit diffs and other rich tool results.
- [ ] Selected search model configuration.
- [ ] Image/other asset deletion and fork reference ownership (shell logs implemented).
- [ ] OpenAI account allowances/reset information and account/model freshness caches.
- [ ] Complete API/client coverage for the above, neutral diagnostics and documentation.

## Verification and delivery

Use isolated stores and fake provider/native transports; never the user's credentials
or live model calls in tests. Test cancellation, approvals, context integrity, durable
mutation failures and restart recovery. Build, test, lint and format each phase before
committing. Live provider compatibility and native permission behavior require separate
explicit checks; mocks cannot verify them. No automatic inference, tool, mutation,
checkpoint, or rotating-token exchange retries. Preserve unrelated repository work.
