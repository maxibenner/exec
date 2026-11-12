import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtemp, readFile, readdir, realpath, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test, { type TestContext } from "node:test";
import { Conversation } from "../src/core/conversation.ts";
import { recoverRecord, validateRecord, type ConversationRecord } from "../src/core/conversation-record.ts";
import type { ChatProvider, ProviderRequest, Tool } from "../src/core/types.ts";
import { AgentManager } from "../src/manager/agent-manager.ts";
import { JsonConversationStore } from "../src/storage/conversation-store.ts";

async function directory(t: TestContext): Promise<string> {
  const root = await realpath(await mkdtemp(join(tmpdir(), "exec-agent-store-")));
  t.after(() => rm(root, { recursive: true, force: true }));
  return root;
}

function provider(): ChatProvider & { requests: ProviderRequest[] } {
  return {
    requests: [],
    async *stream(request) {
      this.requests.push(request);
      yield { type: "text", delta: "Completed answer" };
      yield { type: "done" };
    },
  };
}

function emptyRecord(): ConversationRecord {
  return new Conversation({ provider: provider(), model: "fake", workspace: "/test" }).record();
}

function gate() {
  let release!: () => void;
  const promise = new Promise<void>(resolve => { release = resolve; });
  return { promise, release };
}

async function crash(profile: string, phase: string): Promise<void> {
  const fixture = fileURLToPath(new URL("./fixtures/crash.ts", import.meta.url));
  const child = spawn(process.execPath, [fixture, profile, phase], { env: {}, stdio: ["ignore", "ignore", "pipe"] });
  let stderr = "";
  child.stderr.on("data", chunk => { stderr += String(chunk); });
  const timeout = setTimeout(() => child.kill("SIGKILL"), 5000);
  try {
    await new Promise<void>((resolve, reject) => {
      child.once("error", reject);
      child.once("close", code => code === 0 ? resolve() : reject(new Error(`Fixture failed: ${code}; ${stderr}`)));
    });
  } finally { clearTimeout(timeout); }
}

test("completed conversations round-trip, continue context, and delete durably", async t => {
  const root = await directory(t);
  const profile = join(root, "profile");
  const initialProvider = provider();
  const manager = await AgentManager.open(await JsonConversationStore.open(profile), () => ({ provider: initialProvider }));
  const first = await manager.create({ provider: initialProvider, model: "fake", workspace: root });
  const second = await manager.create({ provider: provider(), model: "other", workspace: root });
  await Promise.all([first.submit("First").completion, second.submit("Second").completion]);
  const expected = first.snapshot();
  await manager.close();
  assert.throws(() => first.submit("Stale client"), /closed/);
  const nextProvider = provider();
  const restored = await AgentManager.open(await JsonConversationStore.open(profile), () => ({ provider: nextProvider }));
  assert.equal(nextProvider.requests.length, 0);
  assert.equal(restored.list().length, 2);
  assert.deepEqual(restored.get(first.id).snapshot(), expected);
  await restored.get(first.id).submit("Continue explicitly").completion;
  assert.deepEqual(nextProvider.requests[0]?.messages, [
    { role: "user", text: "First" },
    { role: "assistant", text: "Completed answer", calls: [] },
    { role: "user", text: "Continue explicitly" },
  ]);
  const oldReference = restored.get(second.id);
  await restored.delete(second.id);
  assert.throws(() => oldReference.submit("Resurrect"), /closed/);
  await restored.close();
  const store = await JsonConversationStore.open(profile);
  assert.deepEqual((await store.load()).map(row => row.id), [first.id]);
  assert.equal((await stat(join(profile, `${first.id}.json`))).mode & 0o777, 0o600);
  assert.equal((await stat(profile)).mode & 0o777, 0o700);
  assert.ok((await readdir(profile)).every(name => !name.endsWith(".tmp")));
  await store.close();
});

for (const phase of ["partial", "approval", "tool"]) {
  test(`abrupt restart at ${phase} boundary never replays work or restores approvals`, { timeout: 10000 }, async t => {
    const root = await directory(t);
    const profile = join(root, "profile");
    await crash(profile, phase);
    await assert.rejects(JsonConversationStore.open(profile), /locked/);
    assert.match(await readFile(join(profile, ".lock", "owner"), "utf8"), /PID:/);
    // Explicit administrator recovery of this test-owned lock, after awaiting
    // the child exit. The production store never steals a crash lock itself.
    await rm(join(profile, ".lock"), { recursive: true });
    let executions = 0;
    const fake = provider();
    const tool: Tool = { definition: { name: "effect", description: "test", parameters: {} },
      async prepare() { return { approval: null, async execute() { executions++; return "unexpected"; } }; } };
    const manager = await AgentManager.open(await JsonConversationStore.open(profile), () => ({ provider: fake, tools: [tool] }));
    const saved = manager.list()[0]!;
    assert.equal(fake.requests.length, 0);
    assert.equal(executions, 0);
    assert.equal(saved.operation?.state, "interrupted");
    assert.equal(saved.approval, null);
    const conversation = manager.get(saved.id);
    assert.equal(conversation.resolveApproval(saved.operation!.id, "old-approval", true), false);
    if (phase === "partial") {
      const message = saved.messages.find(row => row.role === "assistant");
      assert.ok(message?.role === "assistant");
      assert.equal(message.text, "Saved partial response");
      assert.equal(message.status, "interrupted");
    } else {
      const results = saved.messages.filter(row => row.role === "tool");
      assert.deepEqual(results.map(row => row.callID), ["first", "second"]);
      assert.deepEqual(results.map(row => row.outcome), [phase === "tool" ? "interrupted" : "not_executed", "not_executed"]);
      if (phase === "tool") {
        assert.match(results[0]!.text, /may have had effects/);
        assert.equal(await readFile(join(root, "effect"), "utf8"), "executed once");
      } else await assert.rejects(readFile(join(root, "effect")), { code: "ENOENT" });
    }
    // Recovery itself is checkpointed and stable across another restart.
    await manager.close();
    const again = await AgentManager.open(await JsonConversationStore.open(profile), () => ({ provider: fake }));
    assert.deepEqual(again.get(saved.id).snapshot(), saved);
    await again.get(saved.id).submit("New instruction").completion;
    assert.equal(fake.requests.length, 1);
    if (phase === "partial") assert.equal(fake.requests[0]!.messages.some(row => row.role === "assistant"), false);
    else assert.equal(fake.requests[0]!.messages.filter(row => row.role === "tool").length, 2);
    await again.close();
  });
}

test("profile ownership is exclusive and queued writes capture independent records", async t => {
  const root = await directory(t);
  const store = await JsonConversationStore.open(root);
  await assert.rejects(JsonConversationStore.open(root), /locked/);
  const a = emptyRecord(), b = emptyRecord();
  const saving = store.save(a);
  a.model = "mutated after save call";
  await Promise.all([saving, store.save(b)]);
  const records = await store.load();
  assert.equal(records.length, 2);
  assert.equal(records.find(row => row.id === a.id)?.model, "fake");
  await store.close();
  await assert.rejects(store.save(b), /save/);
  const reopened = await JsonConversationStore.open(root);
  assert.equal((await reopened.load()).length, 2);
  await reopened.close();
});

test("corrupt or unsupported records fail closed and are not overwritten", async t => {
  const root = await directory(t);
  const record = emptyRecord();
  const file = join(root, `${record.id}.json`);
  const malformed = "{invalid JSON";
  await writeFile(file, malformed);
  const fake = provider();
  await assert.rejects(AgentManager.open(await JsonConversationStore.open(root), () => ({ provider: fake })), /restore/);
  assert.equal(await readFile(file, "utf8"), malformed);
  assert.equal(fake.requests.length, 0);
  await writeFile(file, JSON.stringify({ ...record, version: 999 }));
  const store = await JsonConversationStore.open(root);
  await assert.rejects(store.load(), /unsupported/);
  await store.close();
});

test("linked checkpoints are refused and invalid saves leave previous data intact", async t => {
  const root = await directory(t);
  const profile = join(root, "profile");
  const store = await JsonConversationStore.open(profile);
  const record = emptyRecord();
  await store.save(record);
  const before = await readFile(join(profile, `${record.id}.json`), "utf8");
  await assert.rejects(store.save({ ...record, version: 2 } as unknown as ConversationRecord), /unsupported/);
  assert.equal(await readFile(join(profile, `${record.id}.json`), "utf8"), before);
  const outside = join(root, "outside");
  await writeFile(outside, before);
  await symlink(outside, join(profile, `${randomUUID()}.json`));
  await assert.rejects(store.load(), /linked/);
  assert.equal(await readFile(outside, "utf8"), before);
  await store.close();
});

test("record validation rejects orphaned, duplicate, and unpaired terminal tool results", () => {
  const base = emptyRecord();
  base.operation = { id: randomUUID(), state: "running" };
  base.messages = [
    { id: randomUUID(), role: "user", text: "Hi" },
    { id: randomUUID(), role: "assistant", text: "", status: "completed", calls: [
      { id: "call", name: "effect", arguments: {} },
    ] },
  ];
  assert.doesNotThrow(() => validateRecord(base));
  assert.throws(() => validateRecord({ ...base, operation: { ...base.operation, state: "completed" } }), /Invalid/);
  assert.throws(() => validateRecord({ ...base, executingToolID: "unknown" }), /Invalid/);
  const result = { id: randomUUID(), role: "tool", callID: "wrong", text: "done", outcome: "completed" };
  assert.throws(() => validateRecord({ ...base, messages: [...base.messages, result] }), /Invalid/);
  assert.throws(() => validateRecord({ ...base, messages: [...base.messages, { ...result, callID: "call" }, { ...result, callID: "call" }] }), /Invalid/);
});

test("checkpoint failure before inference stops work and blocks later submissions", async () => {
  const fake = provider();
  let writes = 0;
  const conversation = new Conversation({ provider: fake, model: "fake", workspace: "/test",
    async checkpoint() { writes++; throw new Error("raw private storage path"); } });
  const result = await conversation.submit("Hi").completion;
  assert.equal(result.state, "failed");
  assert.equal(writes, 1);
  assert.equal(fake.requests.length, 0);
  assert.match(conversation.snapshot().storageError!, /Could not save/);
  assert.doesNotMatch(JSON.stringify(conversation.snapshot()), /raw private/);
  assert.throws(() => conversation.submit("Retry automatically"), /Reload/);
});

for (const boundary of ["intent", "result"]) {
  test(`failed ${boundary} checkpoint prevents further execution and preserves honest recovery`, async () => {
    let executions = 0, requests = 0;
    const saved: ConversationRecord[] = [];
    const fake: ChatProvider = { async *stream() {
      requests++;
      yield { type: "tool_call", call: { id: "first", name: "effect", arguments: {} } };
      yield { type: "tool_call", call: { id: "second", name: "effect", arguments: {} } };
      yield { type: "done" };
    } };
    const tool: Tool = { definition: { name: "effect", description: "test", parameters: {} },
      async prepare() { return { approval: null, async execute() { executions++; return "effect happened"; } }; } };
    const conversation = new Conversation({ provider: fake, tools: [tool], model: "fake", workspace: "/test",
      async checkpoint(record) {
        if ((boundary === "intent" && record.executingToolID)
          || (boundary === "result" && record.messages.some(row => row.role === "tool"))) throw new Error("disk full");
        saved.push(validateRecord(record));
      } });
    assert.equal((await conversation.submit("Change").completion).state, "failed");
    assert.equal(requests, 1);
    assert.equal(executions, boundary === "result" ? 1 : 0);
    const recovered = recoverRecord(saved.at(-1)!);
    assert.deepEqual(recovered.messages.filter(row => row.role === "tool").map(row => row.outcome),
      [boundary === "result" ? "interrupted" : "not_executed", "not_executed"]);
    assert.throws(() => conversation.submit("Again"), /Reload/);
  });
}

test("terminal success is withheld until its save succeeds, and failure is not retried", async () => {
  const saving = gate(), finish = gate();
  let finalWrites = 0;
  const states: string[] = [];
  const conversation = new Conversation({ provider: provider(), model: "fake", workspace: "/test",
    async checkpoint(record) {
      validateRecord(record);
      if (record.operation?.state === "completed") {
        finalWrites++;
        saving.release();
        await finish.promise;
        throw new Error("final fsync failed");
      }
    } });
  conversation.subscribe(event => { if (event.type === "operation") states.push(event.state); });
  const run = conversation.submit("Hi");
  await saving.promise;
  assert.equal(conversation.busy, true);
  assert.notEqual(conversation.snapshot().operation?.state, "completed");
  assert.equal(conversation.cancel(run.operationID), false); // Final commit already started.
  finish.release();
  assert.equal((await run.completion).state, "failed");
  assert.equal(finalWrites, 1);
  assert.equal(states.includes("completed"), false);
});

test("a saved checkpoint with a failed acknowledgement is inspected, never replayed", async t => {
  const root = await directory(t);
  const store = await JsonConversationStore.open(root);
  const fake = provider();
  const conversation = new Conversation({ provider: fake, model: "fake", workspace: root,
    async checkpoint(record) {
      await store.save(record);
      if (record.operation?.state === "completed") throw new Error("Confirmation lost after commit");
    } });
  assert.equal((await conversation.submit("Hi").completion).state, "failed");
  assert.throws(() => conversation.submit("Replay"), /Reload/);
  await store.close();
  const after = provider();
  const manager = await AgentManager.open(await JsonConversationStore.open(root), () => ({ provider: after }));
  assert.equal(manager.get(conversation.id).snapshot().operation?.state, "completed");
  assert.equal(after.requests.length, 0);
  await manager.close();
});

test("manager refuses close during execution and closes retained references afterward", async t => {
  const root = await directory(t);
  const started = gate(), release = gate();
  const fake: ChatProvider = { async *stream() { started.release(); await release.promise; yield { type: "done" }; } };
  const manager = await AgentManager.open(await JsonConversationStore.open(root), () => ({ provider: fake }));
  const conversation = await manager.create({ provider: fake, model: "fake", workspace: root });
  const run = conversation.submit("Hi");
  await started.promise;
  await assert.rejects(manager.close(), /Stop and await/);
  await assert.rejects(JsonConversationStore.open(root), /locked/);
  release.release();
  await run.completion;
  await manager.close();
  assert.throws(() => conversation.submit("Old reference"), /closed/);
});
