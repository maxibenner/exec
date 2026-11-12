# Cross-platform agent runtime and manager

Status: implementation plan. This document does not authorize new dependencies or begin implementation.

## Direction

Build our own cross-platform agent runtime and management layer in TypeScript on Node.js. Do not use Pi, another agent harness, or a hosted agent service as the foundation. Normal infrastructure libraries can be proposed where they materially reduce complexity; they must not own the agent behavior.

This is greenfield. The existing Swift application is the reference for eventual functionality, not an architectural or data compatibility constraint:

- No old conversation migration or preservation of opaque provider context.
- No requirement to preserve existing storage formats, endpoints, class boundaries, or UI state models.
- No compatibility framework or indefinite maintenance of two runtimes.
- Reuse knowledge and behavioral tests from the current implementation, not its accidental coupling.
- Build and verify the runtime/manager first. Once they cover the essential client workflows, rewrite the native client to fit the new foundation.

The goal is the smallest solid, maintainable, flexible foundation for a native UI, CLI, and remote clients. Initial deployment targets are macOS and Linux. Windows remains an intended extension, with support claimed only after platform-specific verification.

## Architecture

```text
Native Exec UI          CLI          Browser / integrations
        \                |                  /
                 HTTP commands + SSE
                          |
                   Service / API
                          |
                       Manager
                          |
                   Agent runtime
                    /          \
             Providers         Tools
                          |
                 Host capabilities
```

Start with one service process and a small set of modules, not microservices. The runtime must also work without HTTP for testing and embedding. The local native client and remote clients use the same public API.

### Runtime

Owns a single conversation's execution:

- Provider-neutral messages, tool calls/results, context, and usage.
- Model streaming and the tool-call loop.
- Input ordering and explicit compaction.
- Approval enforcement, cancellation, and execution outcomes.
- Explicit checkpoint boundaries and operation events.

### Manager

Owns the host's conversations and their lifetimes:

- Conversation catalog, titles, configuration, and workspaces.
- Creation, loading, deletion, forking, and active runtime instances.
- Operation identities, client commands, and pending approval routing.
- Persistence coordination, startup recovery, and shutdown.
- Provider connections, model discovery, and credential ownership.
- Exclusive ownership of the service profile's mutable state.

The manager does not implement a second agent loop. Runtime state and manager metadata each have one authority; do not maintain competing copies of history.

### Service/API

Owns authentication, validation, safe wire types, command receipts, snapshots, events, and transport limits. It does not implement tool policy or provider logic.

### Clients

Own presentation, input, approval decisions, and reconnect behavior. No direct session-file access, provider-token refresh, or independent agent execution.

### Execution location

Tools execute on the runtime host. Workspace paths refer to that host, not the machine displaying the UI. A Linux server must not implicitly run screenshot or shell tools on a connected Mac client.

Expose host capabilities explicitly. Desktop capture is optional Mac-host functionality. Opening Finder or Terminal belongs to the local client's platform integration where applicable.

## Implementation shape

Proposed new top-level directory: `agent/`. Leave `macOS/` in place until the client rewrite. Do not repurpose `Relay/` or `iOS/`.

```text
agent/
  src/
    core/          Domain types, conversation execution, context
    providers/     OpenAI, DeepSeek, auth, model discovery, wire formats
    tools/         File/shell/network tools and execution policy
    manager/       Conversations, operations, configuration, lifecycle
    storage/       Sessions, artifacts, credential-store implementations
    service/       API routes, validation, snapshots, events, auth
    cli/           API client and terminal presentation
  tests/
```

Start with one TypeScript package and clear module boundaries. Split packages only when independent consumption makes it useful. Select and pin a supported Node release and lock dependencies during bootstrap.

Use small explicit interfaces for provider behavior, credential storage, and host capabilities. Avoid a generic plugin framework, universal dependency injection container, or speculative multi-backend architecture.

Use a maintained HTTP implementation and runtime request validation rather than hand-writing a production HTTP parser or assuming TypeScript types validate JSON. Propose exact dependencies before adoption.

## Behavioral requirements

### Provider boundary

The runtime speaks a provider-neutral interface, similar in purpose to the existing `ChatProvider`, not OpenAI request/response types.

Provider implementations own authentication, model discovery, request encoding, stream decoding, opaque continuation context, and provider-specific usage information. Unsupported capabilities must be explicit rather than silently approximated.

Initial providers: OpenAI subscription authentication and DeepSeek API-key authentication, matching current functionality. Implement one end-to-end first, then the second to validate the boundary. Verify live compatibility separately from fake-transport tests.

No automatic retries of inference or rotating-token exchanges. Read-only metadata refresh can have its own deliberately bounded policy; it must not accidentally reuse inference retry logic.

### Conversation and operation integrity

- One active operation per conversation; independent conversations may execute concurrently.
- Acceptance is not completion. Commands return identifiable receipts/resources; operation state reports completion separately.
- Distinguish running, awaiting approval, cancelling, completed, failed, and interrupted.
- Separate visible transcript from valid completed provider context.
- Preserve tool-call/result ordering. Never create successful context from a partial or interrupted action.
- Cancellation targets a specific operation ID, not whatever happens to be running later.
- Disconnecting a client does not cancel an operation.
- On restart, unfinished work becomes interrupted; never automatically replay it.
- Cancellation or transport failure does not imply that an external action had no effects.

Initially reject input while busy with a typed response. Before feature completion, add explicit pending-input/steering semantics comparable to the current app: input must not corrupt context, duplicate execution, or approve a superseded action. Specify this separately rather than hiding a queue inside message submission.

### Tools and approvals

- Read/list/search files within the configured workspace, preserving clear path and symlink rules.
- Revision-checked edits: prepare the exact change, approve that change, then revalidate before writing.
- Shell commands with explicit working directory, timeout, cancellation, bounded output, and retained overflow logs.
- Approval details show the exact command or edit and relevant scope.
- Approval decisions bind to approval ID and operation ID; stale or duplicate decisions cannot authorize another action.
- Permission checks occur at the execution boundary for every invocation path.
- Noninteractive clients never silently enable auto-approval.
- Define explicit auto-approval policy. Do not inherit an unsafe default merely because the current UI uses it.
- Session-scoped screenshot permission is distinct from general tool authorization unless the user explicitly selects a broader policy.
- Errors and denials become honest tool results; do not encourage automatic retries of denied or interrupted actions.

Workspace restrictions are not a sandbox, particularly when arbitrary shell commands are allowed. Stronger OS isolation is a separate requirement, not an implied property.

### Context, persistence, and artifacts

- Durable conversation catalog, messages, configuration, and checkpoints.
- Explicit compaction with preserved cancellation/error semantics.
- Fork from a well-defined completed context boundary, including while another operation is active if a valid completed checkpoint exists.
- Images, screenshots, generated images, and shell logs stored as artifacts with stable references and bounded retention rules.
- No raw provider context in public client responses.
- No success acknowledgement for a durable operation until its documented persistence boundary is met.
- Storage failures must not silently overwrite the last valid completed context.

Use a single documented data directory per service profile and an exclusive profile lock. Choose a minimal durable storage design in milestone 0; avoid both a speculative database platform and a fragile collection of unrelated JSON files when crash consistency requires transactions.

## Event and API contract

Use `/api/v1`, ordinary HTTP commands, and SSE for updates. Clients load snapshots and then follow changes through a defined snapshot/cursor handoff that cannot lose updates.

Core resources:

- Service: version, readiness, server epoch, supported capabilities.
- Conversations: list, create, inspect, rename, configure, delete, fork.
- Messages: submit and read transcript.
- Operations: inspect, cancel, compact.
- Approvals: inspect and resolve.
- Models/providers: supported models/options and safe connection state.
- Artifacts: authenticated upload/download with size/type limits.
- Events: conversation, message, tool, approval, and operation updates.

Finalize exact routes around the first vertical slice. Do not design an exhaustive generic REST framework in advance.

### Recovery and idempotency

- Client-generated request IDs and a server epoch for mutating commands.
- Identical repeated commands within an epoch return their receipt; conflicting reuse is rejected.
- Old-epoch commands are rejected after restart, not silently executed again.
- A receipt records acceptance, not successful inference/tool completion.
- Bound receipt storage without evicting records in a way that permits accidental duplicate execution; reject new commands when safety capacity is exhausted.
- Reconnect event subscriptions safely; do not automatically resubmit agent work.
- Bound event retention. If a cursor is unavailable, require a fresh snapshot.
- Events are delivery records, not a requirement for an event-sourced database or persistence of every token delta.
- Include resource revisions where necessary to reject stale configuration or approval changes.

### Multiple clients

Several clients may observe and issue commands against one conversation. Resolve conflicts centrally. Approval resolves once; changing configuration during active work is either rejected or explicitly applies to the next operation. Capture execution configuration at operation start.

## Credentials, security, and deployment

Provider credentials live on the runtime host. Service access credentials are separate from provider credentials. Clients receive connection metadata, not provider tokens.

- macOS: Keychain-backed storage. Choose a minimal native bridge/helper and verify stable signing and access behavior; do not silently relax controls.
- Linux: explicitly choose a restricted credential store or secret-manager integration and document protection at rest. Plaintext storage requires an explicit decision, not a portability fallback.
- Serialize credential updates/refresh. Do not create independent refresh owners for each conversation.
- Tests use fake transports and isolated/in-memory stores, never the user's Keychain or live model calls.
- Never log tokens, authorization URLs, raw auth responses, or personal account identifiers.
- Define subprocess environments explicitly so tools do not automatically inherit provider or service secrets.
- Document that same-user unrestricted shell execution is not isolated from same-user credentials; stronger isolation requires separate OS controls.

Bind to loopback by default. Authenticate native clients and preserve browser-origin/CSRF protections where browser access is supported. Host/Origin headers are not native-client authentication. Avoid permissive CORS.

Remote deployment uses authenticated HTTPS ingress, for example Pangolin. Keep optional connector management and web assets separate from service startup. Verify Pangolin's actual native/CLI authentication flow instead of assuming browser cookies can be reused.

Start single-user, unprivileged, with one service per trust domain. Multi-tenancy and internet-facing user management are out of scope.

Initial provider onboarding may be a local administrative CLI command. Add remote account mutation only with an explicit security design. Linux headless OAuth must be verified independently of desktop browser launch behavior.

Handle shutdown signals with explicit cancellation, bounded subprocess cleanup, and checkpoints. Verify process-tree termination on macOS and Linux; killing a single shell PID is not sufficient evidence that its children stopped.

## Feature coverage target

The eventual runtime should support the same or similar agent functionality as the current Swift app, without reproducing its UI internals.

| Capability | Foundation / later stage |
|---|---|
| Streaming conversations, model/reasoning selection | Foundation |
| OpenAI subscription and DeepSeek API key | One first; both before client feature completion |
| Files, revision-checked edits, shell, approvals | Foundation |
| Persistence, cancellation, interrupted recovery | Foundation |
| Multiple conversations and workspaces | Foundation |
| CLI, authenticated API, reconnect | Foundation |
| Pending input/steering, compaction, fork | Runtime completeness |
| Web search and public page fetch | Runtime completeness |
| Image input, generation, artifact retrieval | Runtime completeness |
| Session titles, model caches, usage/balance where supported | Runtime completeness |
| Screenshot/window capture and permission | Optional macOS host module |
| Remote folder browsing and Pangolin deployment | Service completeness |
| Native UI shortcuts, windows, rendering, updates | Client rewrite, not runtime |

Treat this as a checklist to refine against actual code and product choices, not a demand for exact behavior when a simpler design is better. Explicitly record deferred features rather than silently claiming parity.

## Milestones and acceptance gates

### 0. Agree the contracts and bootstrap

Deliver:

- Short architecture decision record and precise ownership of state.
- Provider-neutral message/tool/event types and operation transitions.
- Initial API/reconnect/receipt contract.
- Storage/checkpoint design and credential-store proposals.
- TypeScript package, pinned toolchain, approved minimal dependencies, and isolated tests.

Acceptance: the first complete workflow is specified without compatibility constraints, competing history owners, or ambiguous cancellation semantics.

### 1. Build one complete agent loop

Implement one provider adapter and the core loop with fake transport first. Add read/list/search, revision-checked edit, and bounded shell tools. Add approvals, streaming, and cancellation. Keep it usable directly without HTTP.

Acceptance:

- Text and tool-call streaming decode correctly, including split/partial transport frames.
- A tool cannot execute before required approval; denial is final for that request.
- Cancellation works during streaming, approval, and shell execution.
- A partial response or tool result does not become completed context.
- No automatic inference/tool retries occur.

### 2. Add durable management and provider lifecycle

Implement catalog, workspaces, active runtime ownership, checkpoints, restore, exclusive profile ownership, model discovery, and credential coordination. Add the second provider to test the boundary.

Acceptance:

- Two conversations do not leak messages, context, or approvals into one another.
- Restart marks unfinished work interrupted and restores valid completed context.
- Failed writes do not falsely report durable success or destroy valid saved state.
- Provider-specific context remains confined to its adapter/storage boundary.
- macOS and Linux tests cover temporary filesystem and subprocess behavior without live services.

### 3. Expose the service and minimal CLI

Implement authenticated API, safe snapshots, SSE, command receipts, resource limits, and a thin CLI. CLI calls the service rather than creating a second agent implementation.

Initial CLI: list/create conversations, send, watch/attach, inspect/resolve approvals, stop. Include machine-readable output and explicit behavior when noninteractive execution requires approval. Keep diagnostics off structured stdout.

Acceptance:

- CLI and a second test client see/control the same state.
- Lost acknowledgements are resolved through receipts rather than duplicate execution.
- Reconnect does not lose state or rerun work.
- Stale approvals/stops cannot affect later operations.
- Unauthorized requests cannot read conversations or execute actions.

### 4. Complete core client-facing functionality

Add explicit pending-input/steering, compaction, fork, web tools, images/artifacts, titles, and supported usage reporting in small verified features. Add optional Mac capture separately.

Acceptance:

- Every feature in the coverage checklist is implemented, explicitly deferred, or deliberately replaced.
- Pending input and approval withdrawal cannot introduce malformed provider context or accidental execution.
- Compaction/fork operate on valid context boundaries and survive cancellation/failure honestly.
- Unsupported host/provider capabilities are discoverable and fail clearly.

A minimal native-client spike may begin after milestone 3 to validate the contract, but do not let the old client's structure dictate the runtime design.

### 5. Verify deployment and rewrite Exec

Package reproducible Mac/Linux service installations and document onboarding. Verify actual authentication and Pangolin deployment separately from mocks, only with explicit approval for live credentials/services.

Rewrite the Swift client with an API client and observable presentation state. Start with a single conversation, then navigation/settings and optional capabilities. Reuse visual components where useful, not the old orchestration.

The app may supervise a bundled local service or connect to an external service. Define ownership explicitly: closing a client must not kill an independently managed service. Define whether an app-owned local service keeps running after the UI exits before shipping.

Acceptance:

- One native client implementation works against local and remote services.
- No provider execution, refresh, or session-file ownership remains in the UI.
- macOS signing/Keychain and Linux headless operation are manually verified or explicitly reported unverified.
- Install/update behavior includes protocol-version compatibility and actionable errors.

### 6. Consolidate and release

Remove superseded native runtime code when the new client is ready; do not migrate legacy conversations. Document the API, configuration, trust model, data directory, backup expectations, and known platform limitations.

Acceptance: clear feature coverage, no accidental dual ownership, no stale compatibility scaffolding, and successful deployment/recovery checks.

## Verification priorities

Keep tests practical and focused on meaningful behavior:

- Stream parsing, tool-call/result ordering, and context integrity.
- Approval races, stale decisions, and revision conflicts.
- Duplicate submission, lost acknowledgement, and restart after acceptance.
- Cancellation during side effects, subprocess timeout, and output limits.
- Pending input superseding an unexecuted approval.
- Failed/ambiguous authentication refresh and checkpoint failures.
- Expired event cursor and snapshot/subscription races.
- Unauthorized access and absence of secrets/opaque context in public data.

Use fake transports, synthetic auth data, temporary directories, and isolated stores. Mocks do not verify live providers, platform signing/Keychain, or Pangolin. Add macOS/Linux automation early; Windows requires its own checks before being advertised.

For future macOS code changes, run `./scripts/test.sh` and `./scripts/build-app.sh` from `macOS/` before committing. Documentation-only planning does not require a Swift rebuild.

## Scope control and effort

This is a multi-stage implementation, not a syntax translation. A first streaming demo is not a finished runtime. Re-estimate after milestone 1 and again after milestone 3, using working behavior and failing cases rather than line-count parity.

Stop and review if a feature requires duplicate agent loops, competing transcript stores, a generic plugin framework, distributed scheduling, or unnecessary process boundaries.

Out of scope initially: legacy data migration, multi-tenant hosting, sandbox orchestration, arbitrary client-side tool execution from a remote host, mobile app implementation, and a full-screen terminal UI.

## Existing code to consult

Behavioral references only:

- `macOS/Sources/Exec/App/ChatStore.swift`: execution, pending input, compaction, context.
- `macOS/Sources/Exec/App/ChatLibrary.swift`: conversation/provider management.
- `macOS/Sources/Exec/Core/ChatProvider.swift`: provider-neutral boundary.
- `macOS/Sources/Exec/Core/ToolExecutor.swift`: approval/cancellation behavior.
- `macOS/Sources/Exec/Core/FileEdit.swift`: revision-checked changes.
- `macOS/Sources/Exec/Core/ShellRunner.swift`: shell lifecycle.
- `macOS/Sources/Exec/Providers/`: authentication and provider protocol behavior.
- `macOS/Sources/Exec/Storage/`: checkpoints, artifacts, and credentials.
- `macOS/Sources/Exec/Remote/RemoteAPI.swift`: safe responses and command receipts.
- `macOS/Tests/`: regression scenarios to translate selectively.
