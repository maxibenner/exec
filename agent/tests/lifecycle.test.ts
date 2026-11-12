import assert from "node:assert/strict";
import test from "node:test";
import { Conversation } from "../src/core/conversation.ts";
import type { ChatProvider, ConversationSnapshot, RuntimeEvent, Tool } from "../src/core/types.ts";

function gate() {
  let release!: () => void;
  const promise = new Promise<void>(resolve => { release = resolve; });
  return { promise, release };
}
function provider(ids = ["first"]): ChatProvider {
  return { async *stream(request) {
    if (!request.messages.some(message => message.role === "tool")) {
      for (const id of ids) yield { type: "tool_call", call: { id, name: "effect", arguments: {} } };
    }
    yield { type: "done" };
  } };
}
const definition = { name: "effect", description: "Test effect", parameters: {} };

test("live tool ownership excludes approval and durable intent, survives cancellation, and never restores", { timeout: 5000 }, async t => {
  const pending = gate(), intent = gate(), allowExecution = gate(), entered = gate(), cleanup = gate();
  const observed: { event: RuntimeEvent; snapshot: ConversationSnapshot }[] = [];
  let executions = 0;
  const tool: Tool = { definition, async prepare() { return {
    approval: "Exact action", async execute() { executions++; await cleanup.promise; return "effect settled"; },
  }; } };
  const options = { provider: provider(["first", "second"]), model: "fake", workspace: "/isolated", tools: [tool] };
  const conversation = new Conversation({ ...options, async checkpoint(record) {
    if (record.executingToolID === "first") { intent.release(); await allowExecution.promise; }
  } });
  conversation.subscribe(event => {
    observed.push({ event, snapshot: conversation.snapshot() });
    if (event.type === "approval" && event.approvalID) pending.release();
    if (event.type === "tool_started") entered.release();
  });
  const run = conversation.submit("Act");
  t.after(async () => {
    conversation.cancel(run.operationID); allowExecution.release(); cleanup.release(); await run.completion;
  });
  await pending.promise;
  const approval = conversation.snapshot().approval!;
  assert.equal(conversation.snapshot().activeToolCallID, null);
  assert.equal(executions, 0);
  conversation.resolveApproval(run.operationID, approval.id, true);
  await intent.promise;
  assert.equal(conversation.record().executingToolID, "first");
  assert.equal(conversation.snapshot().activeToolCallID, null, "intent is not executor entry");
  assert.equal(observed.some(row => row.event.type === "tool_started"), false);

  const recovered = new Conversation(options, conversation.record());
  assert.equal(recovered.snapshot().activeToolCallID, null);
  assert.equal(recovered.snapshot().approval, null);
  assert.equal(recovered.snapshot().operation?.state, "interrupted");
  assert.equal(executions, 0, "recovering intent must not execute anything");

  allowExecution.release();
  await entered.promise;
  assert.equal(conversation.snapshot().activeToolCallID, "first");
  assert.equal(executions, 1);
  assert.equal(conversation.cancel(run.operationID), true);
  assert.equal(conversation.snapshot().operation?.state, "cancelling");
  assert.equal(conversation.snapshot().activeToolCallID, "first", "cleanup still owns the executor");
  assert.equal(conversation.busy, true);
  cleanup.release();
  assert.equal((await run.completion).state, "interrupted");
  assert.equal(conversation.snapshot().activeToolCallID, null);
  const lifecycle = observed.filter(row => row.event.type === "tool_started" || row.event.type === "tool_finished");
  assert.deepEqual(lifecycle.map(({ event }) => event.type), ["tool_started", "tool_finished", "tool_finished"]);
  assert.equal(lifecycle[0]?.snapshot.activeToolCallID, "first");
  assert.ok(lifecycle.slice(1).every(row => row.snapshot.activeToolCallID === null));
  const finished = lifecycle.flatMap(({ event }) => event.type === "tool_finished" ? [event] : []);
  assert.deepEqual(finished.map(event => [event.callID, event.outcome]), [["first", "interrupted"], ["second", "not_executed"]]);
  for (const event of finished) {
    assert.equal(conversation.snapshot().messages.find(message => message.id === event.messageID)?.role, "tool");
    assert.equal(event.operationID, run.operationID);
  }
});

for (const phase of ["denied", "cancelled approval", "preparation", "synchronous throw", "completed"] as const) {
  test(`tool lifecycle reports ${phase} without inventing or duplicating execution`, async () => {
    const events: RuntimeEvent[] = [];
    const tool: Tool = { definition, async prepare() {
      if (phase === "preparation") throw new Error("Preparation failed");
      return { approval: phase === "denied" || phase === "cancelled approval" ? "Please approve" : null, execute() {
        if (phase === "synchronous throw") throw new Error("Entered then failed");
        return Promise.resolve("done");
      } };
    } };
    const conversation = new Conversation({ provider: provider(), model: "fake", workspace: "/isolated", tools: [tool] });
    conversation.subscribe(event => {
      events.push(event);
      if (event.type === "approval" && event.approvalID) {
        if (phase === "cancelled approval") conversation.cancel(event.operationID);
        else conversation.resolveApproval(event.operationID, event.approvalID, false);
      }
    });
    await conversation.submit("Act").completion;
    const expectedStart = phase === "synchronous throw" || phase === "completed";
    assert.equal(events.filter(event => event.type === "tool_started").length, expectedStart ? 1 : 0);
    const finished = events.filter(event => event.type === "tool_finished");
    assert.equal(finished.length, 1);
    assert.equal(finished[0]?.outcome, phase === "denied" ? "denied" : phase === "completed" ? "completed"
      : phase === "cancelled approval" ? "not_executed" : "failed");
    assert.equal(conversation.snapshot().activeToolCallID, null);
  });
}

for (const boundary of ["intent", "result"] as const) {
  test(`failed ${boundary} checkpoint still publishes exactly one result per finalized call`, async () => {
    const events: RuntimeEvent[] = [];
    let executions = 0;
    const tool: Tool = { definition, async prepare() { return {
      approval: null, async execute() { executions++; return "done"; },
    }; } };
    const conversation = new Conversation({ provider: provider(["first", "second"]), model: "fake", workspace: "/isolated", tools: [tool],
      async checkpoint(record) {
        if ((boundary === "intent" && record.executingToolID) ||
          (boundary === "result" && record.messages.some(message => message.role === "tool"))) throw new Error("Save failed");
      } });
    conversation.subscribe(event => { events.push(event); });
    assert.equal((await conversation.submit("Act").completion).state, "failed");
    assert.equal(executions, boundary === "intent" ? 0 : 1);
    assert.equal(events.filter(event => event.type === "tool_started").length, executions);
    assert.deepEqual(events.filter(event => event.type === "tool_finished").map(event => [event.callID, event.outcome]),
      [["first", boundary === "intent" ? "not_executed" : "completed"], ["second", "not_executed"]]);
    assert.equal(conversation.snapshot().activeToolCallID, null);
  });
}
