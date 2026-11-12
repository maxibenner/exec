# Exec agent

An independent TypeScript/Node foundation for Exec's cross-platform agent. No agent framework or runtime dependencies. Node 24 or newer is required; TypeScript runs directly through Node's type stripping, with a separate type-check step.

```sh
cd agent
npm ci --ignore-scripts
npm run check
npm test
```

## Current boundary

This first slice implements the provider-neutral loop and an in-memory manager. It is not yet a usable coding agent or the completion of milestone 1 in [the plan](../docs/cross-platform-agent-plan.md).

- `src/core/types.ts`: provider, tool, context, approval, and event contracts.
- `src/core/conversation.ts`: one conversation runner with streamed text, sequential tool execution, approvals, and cancellation.
- `src/manager/agent-manager.ts`: owns multiple independent runners in one process.
- `tests/runtime.test.ts`: fake providers/tools, including concurrent conversations and interrupted execution.

Still to implement: real provider adapters/authentication, file/shell tools, durable storage/recovery, HTTP/SSE, and the CLI. No credentials are read and no shell commands are executed by this runtime yet. The Swift app remains unchanged.

## Using the core

Create an `AgentManager`, then call `create({ provider, model, workspace, tools })`. Subscribe to the returned conversation before calling `submit(text)` to observe all updates. Submission returns an operation ID and a completion promise; snapshots contain the transcript, latest operation, and pending approval.

Use `resolveApproval(operationID, approvalID, approved)` and `cancel(operationID)` to act on that exact operation. Both return false for stale targets. Snapshots/events are copies; consumers cannot mutate execution state through them. Observer exceptions are isolated from execution, so observers must report their own failures.

One conversation accepts one operation at a time, while different conversations run concurrently. Cancellation requests cooperative cleanup and does not release conversation ownership until the active provider/tool finishes unwinding. Adapters must honor their abort signal. A noncooperative adapter can keep a conversation busy; this is not process isolation or a sandbox.

## Provider and tool contracts

Providers receive fresh provider-neutral context and tool definitions. They yield text deltas, complete parsed tool calls, and an explicit `done` event. Ending without `done` fails the response; partial text remains visible but is not passed back as completed assistant context. Provider adapters own parsing/validation of their wire formats and must not automatically retry inference. Tool calls are not executed until the response finishes successfully.

Tools validate and prepare an action without side effects. A prepared action supplies its exact approval description, or explicitly declares that approval is unnecessary. Only its `execute` callback may perform the action. Implementations must preserve that prepared action and, for file edits, revalidate the revision before writing.

Completed assistant tool-call messages always receive paired tool results, including denial, execution failure, interruption with possible effects, and calls never executed. These outcomes stay in subsequent context so a later explicit user prompt does not erase knowledge of tool side effects. Failed/partial assistant responses do not enter context. New user input is initially rejected while busy; no hidden queue or automatic restart exists.

A finite step limit stops runaway loops. Provider/preparation/execution exceptions are reported through safe generic messages, not raw errors that might include credentials. Successful tool output is intentionally model-visible; each concrete tool must apply its own output bounds and sensitive-data policy.

## Verification limits

Tests use only fake providers/tools and in-memory state. They do not establish live provider compatibility, filesystem/process behavior, credential security, crash recovery, or Linux support. Those checks belong to the subsequent implementations. No native UI or provider code has been changed.
