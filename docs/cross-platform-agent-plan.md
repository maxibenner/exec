# Cross-platform agent runtime and manager

## Direction

Build our own runtime and manager in TypeScript on Node.js, initially for macOS and Linux. No Pi, other agent harness, or hosted agent service as the foundation. Use normal infrastructure libraries only where useful and approved.

This is greenfield. The Swift app is a reference for eventual functionality, not a compatibility constraint. Do not migrate old conversations or preserve existing storage formats, endpoints, or internal architecture. Once the foundation supports the essential workflows, rewrite the native client to fit it.

## Keep the structure small

Start in `agent/` with one package and one service process. These are module boundaries, not separate services:

- **Runtime:** provider calls, streaming, the agent/tool loop, context, approvals, and cancellation.
- **Manager:** conversations, workspaces, configuration, persistence, and credential ownership.
- **Server:** expose the manager through authenticated HTTP commands and streamed events, initially SSE.
- **Clients:** a thin CLI first, then the native Exec UI. Both use the same API locally and remotely.

Keep provider-specific authentication, model discovery, and wire formats behind a small provider-neutral interface. Keep tools separate from the loop. The runtime must also be usable without the server for tests and embedding.

Tools execute on the runtime host; workspace paths refer to that machine. Mac-only features such as screenshots are optional host capabilities, not requirements for a Linux server.

Do not introduce a plugin framework, distributed architecture, generic backend system, or package hierarchy before there is a concrete need.

## Rules to establish early

- Check approval at the tool execution boundary, not only in the UI or API.
- Tie approval and cancellation to the specific action; stale commands must not affect later work.
- Distinguish completed, failed, and interrupted turns. Partial work must not become valid completed context.
- Never automatically retry inference, side-effecting tools, or rotating-token exchanges after ambiguous outcomes.
- One owner manages mutable conversation state and credentials. Do not duplicate the agent loop or transcript storage across layers.
- Client disconnects do not implicitly cancel work. Restarted services do not automatically resume interrupted actions.
- Credentials stay on the runtime host, out of logs and client responses. Preserve Keychain on macOS; explicitly choose the Linux storage approach before using real credentials.
- Bind locally by default and authenticate API access. Remote exposure requires authenticated HTTPS ingress; workspace selection is not a sandbox.

## 1. Working runtime and persistence

First prove one complete workflow without a UI or network server:

> Run a conversation against one provider, stream output, execute approved file/shell tools, cancel safely, and save/reload the conversation.

Build:

- A minimal provider interface and one provider implementation, using fake transport first.
- The conversation loop with explicit completion and interruption states.
- Read/list/search files, revision-checked edits, and shell execution with timeouts, cancellation, and bounded output.
- Approval and denial of exact actions.
- A small manager and the simplest storage design that safely saves completed context and reports interrupted work after restart.

Allow one active operation per conversation. Initially reject additional input while busy rather than implementing a queue immediately. Choose storage around this working lifecycle, not speculative future requirements.

**Done when:** the workflow works end to end; denial prevents execution; cancellation works during streaming, approval, and shell execution; failed saves and interrupted turns do not corrupt valid history. Verify filesystem and subprocess behavior on macOS and Linux.

## 2. API and minimal CLI

Expose the manager through a small API, then use it from a line-oriented CLI:

- List/create conversations and select workspace/model.
- Send messages, inspect history, and watch streaming output.
- Inspect and resolve approvals.
- Stop a specific operation.

Add authentication, request validation, safe response types, and basic resource limits. Keep machine-readable CLI output separate from diagnostics; noninteractive use must not silently enable auto-approval.

At this stage, specify how clients recover after disconnect and check uncertain submissions without executing commands twice. Keep snapshots, events, and command acknowledgements consistent. Choose concrete receipt/cursor mechanisms only as needed to satisfy those behaviors.

**Done when:** two clients can observe the same conversation, reconnect without rerunning work, and safely issue approvals/cancellation. Unauthorized requests cannot read conversations or execute tools. Independent conversations do not share context or approval state.

## 3. Complete useful capabilities, then rewrite Exec

Use the checklist below to add functionality in small verified changes. Implement the second provider early enough to validate the provider boundary. Avoid expanding the architecture merely to anticipate later features.

When the essential workflows fit, rewrite Exec as an API client with presentation state rather than embedded agent orchestration. Reuse visual components where useful. The same client should work with a local service or a remote one.

Handle service packaging, local process ownership, and Pangolin deployment here. Decide explicitly what happens when the app closes; it must not kill an independently managed service. Verify native/CLI access through Pangolin separately from browser login.

**Done when:** agreed client functionality works against local and Linux-hosted services, remaining limitations are documented, and the obsolete native runtime can be removed without compatibility scaffolding.

## Eventual functionality checklist

Same or similar behavior to the Swift app, not exact implementation parity:

- [ ] OpenAI subscription and DeepSeek API-key authentication; model/reasoning selection.
- [ ] Streaming, workspace file tools, edits, shell, approvals, and cancellation.
- [ ] Multiple conversations/workspaces, persistence, and interrupted-state recovery.
- [ ] Pending input/steering, explicit compaction, and fork from valid completed context.
- [ ] Web search and public page fetch.
- [ ] Image input/generation and retrieval of images and shell logs.
- [ ] Titles, model caches, and supported usage/balance reporting.
- [ ] Optional Mac screenshot/window capture with explicit permissions.
- [ ] Remote workspace browsing and Pangolin access.
- [ ] Native client rewritten against the shared API.

Record explicit deferrals instead of claiming parity prematurely. Windows support, multi-tenancy, sandbox orchestration, a full-screen TUI, and remote execution on client devices are not initial requirements.

## Verification and next action

Keep tests focused on approvals, cancellation, conversation integrity, authentication, and error recovery. Use fake transports, temporary workspaces, and isolated credential stores—not the user's Keychain or live model calls. Manual provider, signing, and deployment checks remain separate from mock verification.

Consult `ChatStore`, `ChatLibrary`, `ChatProvider`, tools, providers, and existing regression tests for lessons and behavior. Do not translate their structure mechanically.

Next: bootstrap the TypeScript package with approved minimal dependencies and implement milestone 1. Reassess the plan after that workflow works, before designing the full API or client rewrite.
