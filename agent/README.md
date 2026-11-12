# Exec agent

An independent TypeScript/Node foundation for Exec's cross-platform agent. No agent framework or runtime dependencies. Node 24 or newer is required; TypeScript runs directly through Node's type stripping, with a separate type-check step.

```sh
cd agent
npm ci --ignore-scripts
npm run check
npm test
```

## Current boundary

The package implements the provider-neutral loop, an in-memory manager, and workspace file/shell tools. It is not yet a usable coding agent or the completion of milestone 1 in [the plan](../docs/cross-platform-agent-plan.md).

- `src/core/types.ts`: provider, tool, context, approval, and event contracts.
- `src/core/conversation.ts`: one conversation runner with streamed text, sequential tool execution, approvals, and cancellation.
- `src/manager/agent-manager.ts`: owns multiple independent runners in one process.
- `src/tools/`: bounded file operations, revision-checked edits, and approved shell execution.
- `tests/`: fake-provider runtime tests and real filesystem/subprocess tests in temporary workspaces.

Still to implement: real provider adapters/authentication, durable storage/recovery, full shell-log retention, HTTP/SSE, and the CLI. No provider credentials are read. The Swift app remains unchanged.

## Using the core

Create an `AgentManager`, then call `create({ provider, model, workspace, tools })`. Subscribe to the returned conversation before calling `submit(text)` to observe all updates. Submission returns an operation ID and a completion promise; snapshots contain the transcript, latest operation, and pending approval.

Use `resolveApproval(operationID, approvalID, approved)` and `cancel(operationID)` to act on that exact operation. Both return false for stale targets. Snapshots/events are copies; consumers cannot mutate execution state through them. Observer exceptions are isolated from execution, so observers must report their own failures.

One conversation accepts one operation at a time, while different conversations run concurrently. Cancellation requests cooperative cleanup and does not release conversation ownership until the active provider/tool finishes unwinding. Adapters must honor their abort signal. A noncooperative adapter can keep a conversation busy; this is not process isolation or a sandbox.

## Provider and tool contracts

Providers receive fresh provider-neutral context and tool definitions. They yield text deltas, complete parsed tool calls, and an explicit `done` event. Ending without `done` fails the response; partial text remains visible but is not passed back as completed assistant context. Provider adapters own parsing/validation of their wire formats and must not automatically retry inference. Tool calls are not executed until the response finishes successfully.

Tools validate and prepare an action without side effects. A prepared action supplies its exact approval description, or explicitly declares that approval is unnecessary. Only its `execute` callback may perform the action. Implementations must preserve that prepared action and, for file edits, revalidate the revision before writing.

Completed assistant tool-call messages always receive paired tool results, including denial, execution failure, interruption with possible effects, and calls never executed. These outcomes stay in subsequent context so a later explicit user prompt does not erase knowledge of tool side effects. Failed/partial assistant responses do not enter context. New user input is initially rejected while busy; no hidden queue or automatic restart exists.

A finite step limit stops runaway loops. Raw provider/preparation/execution exceptions are reported through safe generic messages, not raw errors that might include credentials. Tools can deliberately return a `ToolFailure` with a safe, actionable message (such as a revision conflict or bounded shell diagnostics). Tool output is intentionally model-visible; each concrete tool must apply its own output bounds and sensitive-data policy.

## Workspace tools

Pass `createWorkspaceTools()` from `src/tools/index.ts` as the `tools` option when creating a conversation. Each tool captures the workspace and exact action during preparation. Edits and shell commands require approval; listing, reading, and search are read-only.

- `list_files`: one directory, at most 2,000 entries and 32 KiB of output.
- `read_file`: 1–400 numbered lines, a full-file SHA-256 revision, UTF-8 files up to 1 MiB, output up to 32 KiB.
- `search_text`: case-sensitive single-line literal search with entry, depth, time, match, and output limits. Skips hidden/build/dependency entries and refuses symlink traversal; reports incomplete searches.
- `edit_file`: one exact replacement with a matching revision, or exclusive new-file creation. The approval shows escaped exact old/new text. Final checks and writes are serialized across conversations, and ordinary POSIX owner/group/mode are preserved. Targets are replaced atomically after staging; ACLs and extended attributes are **not** retained. Do not use this implementation for metadata-sensitive files.
- `shell`: bash without startup profiles, approved exact command and working directory, 120-second default timeout (1–900 allowed), and bounded combined stdout/stderr. Nonzero exits, timeout, and cancellation are failed/interrupted outcomes with diagnostics, never automatically retried. Truncated output includes its first/last 15,000 bytes; full output is not retained yet.

File tools reject absolute/parent-traversal paths, validate path components, and use no-follow file opens. Node's portable filesystem API does not provide descriptor-relative `openat` traversal or an atomic compare-and-swap replacement: external processes can race ancestor replacement or the final revision check. Internal edits are serialized, but shell commands/external editors are outside that lock. These tools are **not a sandbox** or equivalent to the Swift implementation's descriptor-relative path protections.

Shells run in a separate POSIX process group. Cancellation/timeouts send TERM then KILL, and background jobs in the group are killed when the shell exits. Processes deliberately escaping the group are not contained; pipe cleanup is bounded and reports failure if necessary. Persistent background services are not supported through this tool. Shells use a small explicit environment, not the service's environment, so provider keys and shell startup injection variables are not automatically inherited. Unrestricted same-user shell access can still read same-user files/credentials.

## Verification limits

Tests use fake providers, isolated in-memory state, temporary files, and real local subprocesses. They do not establish live provider compatibility, credential security, crash recovery, or Linux support until run on that platform. No native UI or provider code has been changed.
