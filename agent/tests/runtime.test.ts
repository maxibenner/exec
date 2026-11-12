import assert from "node:assert/strict";
import test from "node:test";
import { Conversation } from "../src/core/conversation.ts";
import { AgentManager } from "../src/manager/agent-manager.ts";
import type { Approval, ChatProvider, ProviderEvent, ProviderRequest, Tool } from "../src/core/types.ts";

type Script = (request: ProviderRequest) => AsyncIterable<ProviderEvent>;

class FakeProvider implements ChatProvider {
  requests: ProviderRequest[] = [];
  constructor(privateScripts: Script[]) { this.scripts = [...privateScripts]; }
  private scripts: Script[];
  stream(request: ProviderRequest): AsyncIterable<ProviderEvent> {
    this.requests.push(request);
    const script = this.scripts.shift();
    assert.ok(script, "Unexpected inference request (possible retry).");
    return script(request);
  }
}

function response(...events: ProviderEvent[]): Script {
  return async function* () { yield* events; };
}

const done: ProviderEvent = { type: "done" };
const call = (id = "call-1"): ProviderEvent => ({
  type: "tool_call", call: { id, name: "change", arguments: { value: "exact action" } },
});

function tool(execute: () => Promise<string>, approval: string | null = "Apply exact action"): Tool {
  return {
    definition: { name: "change", description: "Test action", parameters: { type: "object" } },
    async prepare() { return { approval, execute }; },
  };
}

function create(provider: ChatProvider, tools: Tool[] = []): Conversation {
  return new Conversation({ provider, model: "fake", workspace: "/isolated-test-workspace", tools });
}

function nextApproval(conversation: Conversation): Promise<Approval> {
  return new Promise(resolve => {
    const unsubscribe = conversation.subscribe(event => {
      if (event.type !== "approval" || event.approvalID === null) return;
      const approval = conversation.snapshot().approval;
      assert.ok(approval);
      unsubscribe();
      resolve(approval);
    });
  });
}

function gate() {
  let release!: () => void;
  const promise = new Promise<void>(resolve => { release = resolve; });
  return { promise, release };
}

function untilAborted(signal: AbortSignal): Promise<never> {
  return new Promise((_, reject) => {
    if (signal.aborted) reject(signal.reason);
    else signal.addEventListener("abort", () => reject(signal.reason), { once: true });
  });
}

test("streams text, retains completed context, and isolates snapshots/observers", async () => {
  const provider = new FakeProvider([
    response({ type: "text", delta: "Hello " }, { type: "text", delta: "world" }, done),
    response({ type: "text", delta: "Next" }, done),
  ]);
  const conversation = create(provider);
  const deltas: string[] = [];
  const terminalCancellation: boolean[] = [];
  conversation.subscribe(() => { throw new Error("Disconnected observer"); });
  conversation.subscribe(event => {
    if (event.type === "text") deltas.push(event.delta);
    if (event.type === "operation" && event.state === "completed") {
      terminalCancellation.push(conversation.cancel(event.operationID));
    }
  });
  const first = conversation.submit("Hi");
  assert.throws(() => conversation.submit("Busy"), /busy/);
  assert.equal((await first.completion).state, "completed");
  assert.deepEqual(deltas, ["Hello ", "world"]);
  assert.deepEqual(terminalCancellation, [false]);
  const snapshot = conversation.snapshot();
  snapshot.messages.length = 0;
  assert.equal(conversation.snapshot().messages.length, 2);
  await conversation.submit("Next prompt").completion;
  assert.deepEqual(provider.requests[1]?.messages, [
    { role: "user", text: "Hi" },
    { role: "assistant", text: "Hello world", calls: [] },
    { role: "user", text: "Next prompt" },
  ]);
});

test("approval authorizes only the exact pending operation, once", { timeout: 2000 }, async () => {
  let executions = 0;
  const provider = new FakeProvider([response(call(), done), response({ type: "text", delta: "Finished" }, done)]);
  const conversation = create(provider, [tool(async () => { executions++; return "changed"; })]);
  const approvalPromise = nextApproval(conversation);
  const run = conversation.submit("Make a change");
  const approval = await approvalPromise;
  assert.equal(executions, 0);
  assert.equal(conversation.snapshot().operation?.state, "awaiting_approval");
  assert.equal(conversation.resolveApproval("stale-operation", approval.id, true), false);
  assert.equal(conversation.resolveApproval(run.operationID, "stale-approval", true), false);
  assert.equal(conversation.resolveApproval(run.operationID, approval.id, true), true);
  assert.equal(conversation.resolveApproval(run.operationID, approval.id, true), false);
  assert.equal((await run.completion).state, "completed");
  assert.equal(executions, 1);
  assert.deepEqual(provider.requests[1]?.messages.at(-1), {
    role: "tool", callID: "call-1", text: "changed", outcome: "completed",
  });
});

test("denial produces a tool result without execution", { timeout: 2000 }, async () => {
  let executions = 0;
  const provider = new FakeProvider([response(call(), done), response(done)]);
  const conversation = create(provider, [tool(async () => { executions++; return "unexpected"; })]);
  const pending = nextApproval(conversation);
  const run = conversation.submit("Change");
  const approval = await pending;
  conversation.resolveApproval(run.operationID, approval.id, false);
  assert.equal((await run.completion).state, "completed");
  assert.equal(executions, 0);
  const result = provider.requests[1]?.messages.at(-1);
  assert.equal(result?.role, "tool");
  if (result?.role === "tool") assert.equal(result.outcome, "denied");
});

test("cancellation withdraws approval and pairs all calls without executing", { timeout: 2000 }, async () => {
  let executions = 0;
  const provider = new FakeProvider([response(call("a"), call("b"), done), response(done)]);
  const conversation = create(provider, [tool(async () => { executions++; return "unexpected"; })]);
  const pending = nextApproval(conversation);
  const run = conversation.submit("Change twice");
  const approval = await pending;
  assert.equal(conversation.cancel(run.operationID), true);
  assert.equal(conversation.resolveApproval(run.operationID, approval.id, true), false);
  assert.equal((await run.completion).state, "interrupted");
  assert.equal(executions, 0);
  assert.equal(provider.requests.length, 1);
  assert.equal(conversation.snapshot().approval, null);
  const results = conversation.snapshot().messages.filter(row => row.role === "tool");
  assert.deepEqual(results.map(row => row.outcome), ["not_executed", "not_executed"]);
  const next = conversation.submit("Do something else");
  assert.equal(conversation.cancel(run.operationID), false);
  assert.equal((await next.completion).state, "completed");
  const contextResults = provider.requests[1]?.messages.filter(row => row.role === "tool");
  assert.deepEqual(contextResults?.map(row => row.callID), ["a", "b"]);
});

test("cancelled streaming stays visible but is excluded from completed context", { timeout: 2000 }, async () => {
  const started = gate();
  const provider = new FakeProvider([
    async function* (request) {
      yield { type: "text", delta: "Partial" };
      started.release();
      await untilAborted(request.signal);
    },
    response(done),
  ]);
  const conversation = create(provider);
  const run = conversation.submit("First");
  await started.promise;
  conversation.cancel(run.operationID);
  assert.equal((await run.completion).state, "interrupted");
  const partial = conversation.snapshot().messages[1];
  assert.ok(partial?.role === "assistant");
  assert.equal(partial.status, "interrupted");
  assert.equal(partial.text, "Partial");
  await conversation.submit("New instruction").completion;
  assert.equal(provider.requests[1]?.messages.some(row => row.role === "assistant"), false);
});

test("incomplete provider output never executes calls and is not retried", async () => {
  let executions = 0;
  const provider = new FakeProvider([response({ type: "text", delta: "Partial" }, call())]);
  const conversation = create(provider, [tool(async () => { executions++; return "unexpected"; }, null)]);
  const result = await conversation.submit("Change").completion;
  assert.equal(result.state, "failed");
  assert.equal(provider.requests.length, 1);
  assert.equal(executions, 0);
  const message = conversation.snapshot().messages[1];
  assert.ok(message?.role === "assistant");
  assert.equal(message.status, "failed");
  assert.deepEqual(message.calls, []);
});

test("duplicate call IDs fail before any tool executes", async () => {
  let executions = 0;
  const provider = new FakeProvider([response(call(), call(), done)]);
  const conversation = create(provider, [tool(async () => { executions++; return "unexpected"; }, null)]);
  assert.equal((await conversation.submit("Change").completion).state, "failed");
  assert.equal(executions, 0);
});

test("running tool cancellation waits for cleanup and records possible effects", { timeout: 2000 }, async () => {
  const started = gate();
  const release = gate();
  let executions = 0;
  const provider = new FakeProvider([response(call("a"), call("b"), done)]);
  const conversation = create(provider, [tool(async () => {
    executions++;
    started.release();
    // Deliberately slow to stop: a runtime must not release ownership too early.
    await release.promise;
    return "Possibly changed";
  }, null)]);
  const run = conversation.submit("Change twice");
  await started.promise;
  conversation.cancel(run.operationID);
  assert.equal(conversation.busy, true);
  assert.throws(() => conversation.submit("Overlap"), /busy/);
  release.release();
  assert.equal((await run.completion).state, "interrupted");
  assert.equal(executions, 1);
  assert.equal(provider.requests.length, 1);
  const results = conversation.snapshot().messages.filter(row => row.role === "tool");
  assert.deepEqual(results.map(row => row.outcome), ["interrupted", "not_executed"]);
  assert.match(results[0]!.text, /may have had effects/);
});

test("provider exceptions do not leak raw errors or trigger retries", async () => {
  const provider = new FakeProvider([async function* () { throw new Error("secret token raw response"); }]);
  const conversation = create(provider);
  assert.equal((await conversation.submit("Hi").completion).state, "failed");
  assert.doesNotMatch(JSON.stringify(conversation.snapshot()), /secret token/);
  assert.equal(provider.requests.length, 1);
});

test("step limit stops a tool loop without sending another request", async () => {
  const provider = new FakeProvider([response(call(), done)]);
  const conversation = new Conversation({ provider, model: "fake", workspace: "/test", maxSteps: 1,
    tools: [tool(async () => "done", null)] });
  const operation = await conversation.submit("Change").completion;
  assert.equal(operation.state, "failed");
  assert.match(operation.error!, /step limit/);
  assert.equal(provider.requests.length, 1);
});

test("cancellation before startup makes no inference request", async () => {
  const provider = new FakeProvider([]);
  const conversation = create(provider);
  const run = conversation.submit("Cancel immediately");
  assert.equal(conversation.cancel(run.operationID), true);
  assert.equal((await run.completion).state, "interrupted");
  assert.equal(provider.requests.length, 0);
});

test("cancellation after approval but before execution still prevents effects", { timeout: 2000 }, async () => {
  let executions = 0;
  const provider = new FakeProvider([response(call(), done)]);
  const conversation = create(provider, [tool(async () => { executions++; return "unexpected"; })]);
  const pending = nextApproval(conversation);
  const run = conversation.submit("Change");
  const approval = await pending;
  conversation.resolveApproval(run.operationID, approval.id, true);
  conversation.cancel(run.operationID);
  assert.equal((await run.completion).state, "interrupted");
  assert.equal(executions, 0);
  assert.equal(conversation.snapshot().approval, null);
});

test("preparation errors do not execute or expose raw errors", async () => {
  const provider = new FakeProvider([response(call(), done), response(done)]);
  const failingTool = tool(async () => "unreachable");
  failingTool.prepare = async () => { throw new Error("private credential"); };
  const conversation = create(provider, [failingTool]);
  assert.equal((await conversation.submit("Change").completion).state, "completed");
  const result = provider.requests[1]?.messages.at(-1);
  assert.ok(result?.role === "tool");
  assert.equal(result.outcome, "failed");
  assert.match(result.text, /did not execute/);
  assert.doesNotMatch(JSON.stringify(conversation.snapshot()), /private credential/);
});

test("manager runs conversations concurrently with independent cancellation/context", { timeout: 2000 }, async () => {
  const firstStarted = gate();
  const secondStarted = gate();
  const releaseSecond = gate();
  const firstProvider = new FakeProvider([async function* (request) {
    firstStarted.release();
    await untilAborted(request.signal);
  }]);
  const secondProvider = new FakeProvider([async function* () {
    secondStarted.release();
    await releaseSecond.promise;
    yield { type: "text", delta: "Independent" };
    yield done;
  }]);
  const manager = new AgentManager();
  const first = await manager.create({ provider: firstProvider, model: "a", workspace: "/first" });
  const second = await manager.create({ provider: secondProvider, model: "b", workspace: "/second" });
  const a = first.submit("First conversation");
  const b = second.submit("Second conversation");
  await Promise.all([firstStarted.promise, secondStarted.promise]);
  assert.equal(manager.list().filter(row => row.operation?.state === "running").length, 2);
  await assert.rejects(manager.delete(first.id), /active/);
  first.cancel(a.operationID);
  assert.equal((await a.completion).state, "interrupted");
  assert.equal(second.busy, true);
  releaseSecond.release();
  assert.equal((await b.completion).state, "completed");
  assert.deepEqual(secondProvider.requests[0]?.messages, [{ role: "user", text: "Second conversation" }]);
  assert.equal(firstProvider.requests.length, 1);
  await manager.delete(first.id);
  assert.deepEqual(manager.list().map(row => row.id), [second.id]);
});
