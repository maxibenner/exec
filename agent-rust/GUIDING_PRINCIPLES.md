# Guiding principles

Build a small, authoritative, provider-neutral execution engine with thin clients, explicit lifecycles, exact permissions, truthful history, and conservative behavior whenever the outcome is uncertain.

These principles consolidate the design of the original TypeScript system, documented in the [architecture plan](../docs/cross-platform-agent-plan.md), [runtime documentation](../agent/README.md), and [API design](../agent/API.md). They carry forward into the Rust implementation. The design drew in part on learnings from the OpenAI Codex repository; this document records our project's choices, not quotations or individually attributed Codex rules.

These are design constraints and development guidance, not a claim that every planned capability is implemented. See [README.md](README.md), [API.md](API.md), and [TEST_PARITY.md](TEST_PARITY.md) for current behavior, scope, and verification limits.

## Architecture and simplicity

### 1. Own the core agent runtime

Build our own conversation loop and manager rather than making an agent framework or hosted harness the foundation.

Use ordinary infrastructure libraries where useful, but keep orchestration, state ownership, approvals, and recovery under our control. Learn from Codex and the existing Swift app without mechanically copying their architecture.

### 2. Keep the system small and understandable

Start with one package, one service process, and clear internal modules.

Prefer straightforward control flow, explicit interfaces, composition, and existing components. Do not introduce microservices, a plugin framework, a generic backend system, or elaborate package hierarchies before a concrete requirement justifies them.

**Design for extension, but do not build speculative infrastructure.**

### 3. Separate responsibilities clearly

- **Runtime:** provider calls, streaming, the agent/tool loop, context, approvals, and cancellation.
- **Manager:** conversation lifecycle, configuration, workspaces, and persistence.
- **Providers:** authentication integration, model discovery, provider wire formats, and provider-specific context.
- **Tools:** preparation, validation, and execution of concrete actions.
- **Server:** validated commands and observable state/events.
- **Clients:** interaction and presentation—not another agent loop.

The runtime must remain usable without the server for testing and embedding.

### 4. Have one authoritative owner of execution state

The service owns conversations, active operations, pending approvals, and durable history.

Clients may maintain presentation state, but must not independently orchestrate execution or maintain competing authoritative transcripts. Multiple clients should observe and control the same underlying conversation.

### 5. Keep the runtime provider-neutral

The loop and clients depend on a small `ChatProvider` contract, not OpenAI or DeepSeek request formats.

Provider-specific authentication, request encoding, streaming decoding, capabilities, and opaque context belong behind that boundary. Do not mistake superficially similar APIs for identical provider behavior.

## Execution and safety

### 6. Make concurrency explicit and isolated

Allow independent conversations to run concurrently, but initially permit only one active operation per conversation.

Each conversation owns its context, approval state, cancellation, and execution lifecycle. Reject input while busy rather than silently queueing it or inventing steering behavior.

### 7. Enforce approvals at the execution boundary

Approval is a runtime invariant—not merely a UI prompt.

Tools first **prepare an exact action without side effects**, including its approval description. Only execution may perform the action. Approval must authorize that prepared action, not a recomputed or subsequently changed one.

For file edits, revalidate the revision immediately before writing.

### 8. Target commands precisely

Approval and cancellation must identify the specific operation and, where applicable, the specific approval/action.

Stale commands must never affect later work. Approval decisions are single-use. Enabling tools is not blanket authorization, and having no client connected is never implicit permission.

### 9. Treat cancellation as a cleanup lifecycle

“Cancellation accepted” does not mean “execution has stopped.”

Keep ownership of the conversation and active executor until provider/tool cleanup finishes. Do not allow overlapping work while cleanup is still running. Cancellation cannot undo side effects, and the recorded outcome must acknowledge that.

### 10. Never automatically repeat ambiguously completed work

A timeout, disconnect, cancellation, or failed acknowledgement does not prove that nothing happened.

Do not automatically retry:

- Inference.
- Side-effecting tools.
- Rotating-token exchanges.
- Mutations or checkpoint writes whose outcome is uncertain.

**Inspect state and require an explicit decision instead of risking duplicate effects.**

### 11. Preserve truthful conversation context

Distinguish completed, failed, interrupted, denied, and never-executed work.

Partial assistant output can remain visible without becoming valid completed provider context. Execute tool calls only after the provider response has completed and the full call batch has been validated.

Every finalized tool call must receive a corresponding result—even if it was denied or never executed. Later turns must retain knowledge of failures and possible side effects.

## Persistence and API design

### 12. Persist around meaningful execution boundaries

Checkpoint the facts needed to explain what happened:

- User input before inference.
- In-flight responses.
- Finalized tool calls.
- Approval state.
- Execution intent before possible effects.
- Tool results.
- Terminal operation state.

Do not publish terminal success before its final checkpoint succeeds. Fail closed on corrupt records or failed persistence rather than continuing with uncertain history.

### 13. Recover conservatively—never replay automatically

Restart restores state, not permission to resume execution.

Mark unfinished work interrupted, clear approval grants and live executor ownership, and reconstruct missing results honestly:

- Saved execution intent means an action **may have had effects**.
- Later actions may be known not to have executed.

Do not silently discard corrupt data, promote temporary files, steal ownership locks, or rerun interrupted actions.

### 14. Separate commands, observations, and durable guarantees

The API must distinguish:

- **Command acceptance:** the request was accepted.
- **Execution events:** something started or changed.
- **Settlement:** execution and cleanup finished.
- **Durability:** the relevant state was successfully saved.

These are different guarantees. A `202`, a tool-start event, or a tool-result event must not imply more than it actually establishes.

### 15. Make reconnecting safe without repeating commands

Clients reconnect to obtain a current snapshot and then follow live events.

Snapshots reconcile authoritative state; text deltas append incremental output. Disconnecting does not cancel work, approve tools, or restart inference. Slow or broken observers must not block execution.

Avoid adding replay logs, cursors, queues, or idempotency mechanisms until a concrete requirement needs them.

## Security, portability, and verification

### 16. Keep security boundaries honest

Validate inputs and bound streams, files, searches, subprocess output, execution time, and loop steps.

Keep credentials outside workspaces and conversation records. Never expose secrets through diagnostics or automatically inherit them into tool subprocesses.

Local access should be private; remote exposure requires deliberate authenticated transport. **A selected workspace and an approval prompt are not a sandbox.**

### 17. Keep execution host-based and clients portable

Tools execute on the runtime host; workspace paths refer to that machine.

The CLI and eventual native UI should use the same API. Platform-specific capabilities, such as macOS screenshots, should be optional host capabilities—not assumptions embedded throughout the core.

### 18. Prove behavior incrementally and report limitations honestly

Build one complete workflow before expanding the architecture.

Prioritize tests for approvals, cancellation, conversation integrity, authentication, persistence, and error recovery. Use fake transports and isolated stores, alongside real filesystem/socket/subprocess tests where those boundaries matter.

Keep live-provider and deployment verification separate from mock testing. Record explicit deferrals rather than claiming premature feature parity.
