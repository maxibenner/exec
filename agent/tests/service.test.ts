import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { mkdtemp, mkdir, readFile, realpath, rm, stat, symlink, writeFile } from "node:fs/promises";
import { createServer, request } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import test, { type TestContext } from "node:test";
import type { ChatProvider, ConversationSnapshot, Tool } from "../src/core/types.ts";
import { AgentManager } from "../src/manager/agent-manager.ts";
import { AgentClient } from "../src/client/agent-client.ts";
import { followConversation, terminalText, Transcript } from "../src/client/terminal.ts";
import { APIError, activeOperation } from "../src/service/protocol.ts";
import { startPersistentService } from "../src/service/persistent-service.ts";
import { privateDirectory, profileSocket, startService } from "../src/service/server.ts";

const echo: ChatProvider = {
  async models() { return [{ id: "fake", name: "Fake" }]; },
  async *stream() { yield { type: "text", delta: "Hello 🌍" }; yield { type: "done" }; },
};
const status = (expected: number) => (error: unknown) => error instanceof APIError && error.status === expected;
function gate() {
  let release!: () => void;
  const promise = new Promise<void>(resolve => { release = resolve; });
  return { promise, release };
}
async function directory(): Promise<string> {
  return realpath(await mkdtemp(join(tmpdir(), "ea-")));
}
async function setup(t: TestContext, provider = echo, tools: Tool[] = []) {
  const root = await directory();
  const manager = new AgentManager();
  const service = await startService({ manager, provider, tools, socketPath: profileSocket(root) });
  t.after(async () => { await service.close(); await rm(root, { recursive: true, force: true }); });
  return { root, manager, service, client: new AgentClient(profileSocket(root)) };
}
async function until(client: AgentClient, id: string, predicate: (snapshot: ConversationSnapshot) => boolean) {
  for await (const event of client.events(id, AbortSignal.timeout(4000))) {
    if (event.snapshot && predicate(event.snapshot)) return event.snapshot;
  }
  throw new Error("Expected service snapshot was not observed.");
}
const terminal = (client: AgentClient, id: string) => until(client, id, snapshot => !!snapshot.operation && !activeOperation(snapshot));

// All endpoints use a real local HTTP socket. Providers and credential sources
// are fake; tests never consult the user's profile, Keychain, or paid services.
test("API create, stream, reconnect snapshot and saved conversation continuation", { timeout: 10000 }, async t => {
  const root = await directory();
  let calls = 0;
  const provider: ChatProvider = { async *stream() { calls++; yield { type: "text", delta: "Hello 🌍" }; yield { type: "done" }; } };
  let service = await startPersistentService({ profile: root, provider });
  t.after(async () => { await service.close(); await rm(root, { recursive: true, force: true }); });
  const client = new AgentClient(profileSocket(root));
  assert.deepEqual(await client.health(), { version: 1, toolsEnabled: false });
  const conversation = await client.create("fake", root);
  const submitted = await client.submit(conversation.id, "Hi");
  const saved = await terminal(client, conversation.id);
  assert.equal(saved.operation?.id, submitted.operationID);
  assert.equal(saved.messages.at(-1)?.text, "Hello 🌍");
  const iterator = client.events(conversation.id);
  assert.deepEqual((await iterator.next()).value, { type: "snapshot", snapshot: saved });
  await iterator.return(undefined);
  assert.equal((await client.list())[0]?.id, conversation.id);
  assert.equal("messages" in (await client.list())[0]!, false);
  assert.equal((await stat(profileSocket(root))).mode & 0o777, 0o600);
  await service.close();
  service = await startPersistentService({ profile: root, provider });
  assert.deepEqual(await client.get(conversation.id), saved);
  assert.equal(calls, 1, "opening a profile must not resume inference");
  await client.submit(conversation.id, "Continue explicitly");
  assert.equal((await terminal(client, conversation.id)).messages.length, 4);
  assert.equal(calls, 2);
  const disk = await readFile(join(root, "conversations", `${conversation.id}.json`), "utf8");
  assert.equal(JSON.parse(disk).operation.state, "completed");
});

test("same-conversation exclusion, cross-conversation concurrency and explicit cancellation", { timeout: 10000 }, async t => {
  const entered = gate();
  let calls = 0;
  const provider: ChatProvider = { async *stream(request) {
    calls++;
    if (request.messages.at(-1)?.text === "hold") {
      yield { type: "text", delta: "partial" };
      entered.release();
      await new Promise<void>(resolve => {
        if (request.signal.aborted) resolve();
        else request.signal.addEventListener("abort", () => resolve(), { once: true });
      });
      request.signal.throwIfAborted();
    }
    yield { type: "done" };
  } };
  const { client, root } = await setup(t, provider);
  const first = await client.create("fake", root);
  const second = await client.create("fake", root);
  const run = await client.submit(first.id, "hold");
  await entered.promise;
  await assert.rejects(client.submit(first.id, "duplicate"), status(409));
  await assert.rejects(client.cancel(first.id, randomUUID()), status(409));
  await client.submit(second.id, "independent");
  assert.equal((await terminal(client, second.id)).operation?.state, "completed");
  const observer = client.events(first.id);
  await observer.next();
  await observer.return(undefined);
  assert.equal((await client.get(first.id)).operation?.state, "running", "detaching does not cancel work");
  await client.cancel(first.id, run.operationID);
  const interrupted = await terminal(client, first.id);
  assert.equal(interrupted.operation?.state, "interrupted");
  assert.equal(interrupted.messages.at(-1)?.text, "partial");
  assert.equal(calls, 2);
});

for (const approved of [true, false]) {
  test(`API approval is exact, single use, and ${approved ? "executes" : "denies"} the action`, { timeout: 10000 }, async t => {
    let executed = 0;
    const provider: ChatProvider = { async *stream(request) {
      if (!request.messages.some(message => message.role === "tool")) {
        yield { type: "tool_call", call: { id: "call-1", name: "effect", arguments: {} } };
      }
      yield { type: "done" };
    } };
    const tool: Tool = { definition: { name: "effect", description: "Test effect", parameters: {} },
      async prepare() { return { approval: "Exact test effect", async execute() { executed++; return "done"; } }; } };
    const { root, client } = await setup(t, provider, [tool]);
    const conversation = await client.create("fake", root);
    await client.submit(conversation.id, "Act");
    const pending = await until(client, conversation.id, snapshot => snapshot.approval !== null);
    const approval = pending.approval!;
    assert.equal(executed, 0);
    assert.equal(approval.description, "Exact test effect");
    await assert.rejects(client.approve(conversation.id, randomUUID(), approval.id, true), status(409));
    await assert.rejects(client.approve(conversation.id, approval.operationID, randomUUID(), true), status(409));
    await client.approve(conversation.id, approval.operationID, approval.id, approved);
    await assert.rejects(client.approve(conversation.id, approval.operationID, approval.id, true), status(409));
    const finished = await terminal(client, conversation.id);
    assert.equal(finished.messages.find(message => message.role === "tool")?.outcome, approved ? "completed" : "denied");
    assert.equal(executed, approved ? 1 : 0);
  });
}

test("shutdown cancels and persists pending approvals without executing or restarting them", { timeout: 10000 }, async t => {
  const root = await directory();
  let calls = 0;
  const provider: ChatProvider = { async *stream() {
    calls++;
    yield { type: "tool_call", call: { id: "write", name: "edit_file", arguments: {
      path: "must-not-exist.txt", expected_revision: "new", old_text: "", new_text: "test",
    } } };
    yield { type: "done" };
  } };
  let service = await startPersistentService({ profile: root, provider, workspaceTools: true });
  t.after(async () => { await service.close(); await rm(root, { recursive: true, force: true }); });
  const client = new AgentClient(profileSocket(root));
  const conversation = await client.create("fake", root);
  await client.submit(conversation.id, "Write");
  await until(client, conversation.id, snapshot => snapshot.approval !== null);
  await service.close();
  service = await startPersistentService({ profile: root, provider, workspaceTools: true });
  const restored = await client.get(conversation.id);
  assert.equal(restored.operation?.state, "interrupted");
  assert.equal(restored.approval, null);
  assert.equal(calls, 1);
  await assert.rejects(stat(join(root, "must-not-exist.txt")), { code: "ENOENT" });
});

test("HTTP validation rejects malformed, unknown and browser-origin requests without inference", async t => {
  let calls = 0;
  const { root, client } = await setup(t, { async *stream() { calls++; yield { type: "done" }; } });
  await assert.rejects(client.create("fake", "relative"), status(400));
  await assert.rejects(client.call("POST", "/v1/conversations", { model: "fake", workspace: root, apiKey: "never-read" }), status(400));
  await assert.rejects(client.get("bad/id"), status(400));
  await assert.rejects(client.get(randomUUID()), status(404));
  await assert.rejects(client.call("POST", "/v1/conversations", { model: "fake" }), status(400));
  const conversation = await client.create("fake", root);
  await assert.rejects(client.submit(conversation.id, " "), status(400));
  await assert.rejects(client.call("POST", `/v1/conversations/${conversation.id}/approvals`, {
    operationID: randomUUID(), approvalID: randomUUID(), approved: "true",
  }), status(400));
  const response = await new Promise<number>(resolve => {
    const req = request({ socketPath: profileSocket(root), path: "/v1/health", headers: { Origin: "https://example.com" } }, res => {
      res.resume(); res.on("end", () => resolve(res.statusCode!));
    });
    req.end();
  });
  assert.equal(response, 403);
  assert.equal(calls, 0);
});

test("private socket directory refuses insecure permissions, symlinks, and existing endpoints", async t => {
  const root = await directory();
  t.after(() => rm(root, { recursive: true, force: true }));
  const insecure = join(root, "public");
  await mkdir(insecure, { mode: 0o755 });
  await assert.rejects(privateDirectory(insecure), /private/);
  const link = join(root, "link");
  await symlink(insecure, link);
  await assert.rejects(privateDirectory(link), /private/);
  const socketPath = profileSocket(root);
  await writeFile(socketPath, "do not replace");
  const manager = new AgentManager();
  await assert.rejects(startService({ manager, provider: echo, socketPath }));
  await manager.close();
  assert.equal(await readFile(socketPath, "utf8"), "do not replace");
});

test("model discovery errors and provider failures do not leak internal credentials", async t => {
  const secret = "synthetic-private-error";
  const { root, client } = await setup(t, {
    async models() { throw new Error(secret); },
    async *stream() { throw new Error(secret); },
  });
  await assert.rejects(client.models(), error => !String(error).includes(secret) && status(500)(error));
  const conversation = await client.create("fake", root);
  await client.submit(conversation.id, "Fail once");
  const failed = await terminal(client, conversation.id);
  assert.equal(failed.operation?.state, "failed");
  assert.equal(JSON.stringify(failed).includes(secret), false);
});

test("terminal renderer reconciles snapshot/deltas and escapes terminal control sequences", async t => {
  const { root, client } = await setup(t, echo);
  const conversation = await client.create("fake", root);
  const { operationID } = await client.submit(conversation.id, "Hi");
  let output = "";
  const transcript = new Transcript(text => { output += text; });
  const operation = await followConversation(client, conversation.id, transcript, { operationID });
  transcript.snapshot(await client.get(conversation.id));
  assert.equal(operation?.state, "completed");
  assert.equal(output.split("Hello 🌍").length, 2);
  assert.equal(terminalText("\x1b]52;c;clipboard\x07\r\u202eevil"), "\\u{1b}]52;c;clipboard\\u{7}\\u{d}\\u{202e}evil");
});

test("real CLI process creates, sends, lists and resumes through the service only", { timeout: 10000 }, async t => {
  const { root } = await setup(t);
  const executable = fileURLToPath(new URL("../src/entrypoints/cli.ts", import.meta.url));
  const cli = (...args: string[]) => promisify(execFile)(process.execPath, [executable, "--profile", root, ...args], { timeout: 4000 });
  const created = JSON.parse((await cli("new", "fake", root)).stdout) as ConversationSnapshot;
  assert.match((await cli("send", created.id, "Hi")).stdout, /Hello 🌍/);
  assert.equal(JSON.parse((await cli("list")).stdout)[0].id, created.id);
  const resumed = JSON.parse((await cli("show", created.id)).stdout) as ConversationSnapshot;
  assert.equal(resumed.operation?.state, "completed");
  assert.match((await cli("send", created.id, "Continue")).stdout, /completed/);
  await assert.rejects(cli("chat", created.id), /interactive terminal/);
  await assert.rejects(cli("new", "fake", root, "unexpected"), /Invalid command arguments/);
});

test("service shutdown aborts inference and disconnects observers without client retries", { timeout: 10000 }, async t => {
  const entered = gate();
  let calls = 0;
  let aborted = false;
  const provider: ChatProvider = { async *stream(request) {
    calls++;
    entered.release();
    await new Promise<void>(resolve => {
      if (request.signal.aborted) resolve();
      else request.signal.addEventListener("abort", () => resolve(), { once: true });
    });
    aborted = request.signal.aborted;
    request.signal.throwIfAborted();
  } };
  const { root, client, service } = await setup(t, provider);
  const conversation = await client.create("fake", root);
  await client.submit(conversation.id, "Wait");
  await entered.promise;
  const observer = client.events(conversation.id);
  await observer.next();
  const disconnected = assert.rejects(observer.next(), /interrupted/);
  await service.close();
  await disconnected;
  assert.equal(aborted, true);
  assert.equal(calls, 1);
});

test("lost mutation responses are never replayed and client errors hide raw bodies", { timeout: 10000 }, async t => {
  const root = await directory();
  let attempts = 0;
  const server = createServer((req, res) => {
    attempts++;
    req.resume();
    req.on("end", () => {
      if (req.url?.endsWith("turns")) req.socket.destroy(); // The operation could already have happened.
      else { res.writeHead(500); res.end(JSON.stringify({ error: "synthetic-secret" })); }
    });
  });
  await new Promise<void>(resolve => server.listen(profileSocket(root), resolve));
  t.after(async () => {
    await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(root, { recursive: true, force: true });
  });
  const client = new AgentClient(profileSocket(root));
  await assert.rejects(client.submit(randomUUID(), "Once only"), /may have taken effect/);
  assert.equal(attempts, 1);
  await assert.rejects(client.health(), error => status(500)(error) && !String(error).includes("synthetic-secret"));
  assert.equal(attempts, 2);
});

test("an attached client receives live deltas before terminal completion", { timeout: 10000 }, async t => {
  const finish = gate();
  const receivedText = gate();
  const { root, client } = await setup(t, { async *stream(request) {
    yield { type: "text", delta: "Live 🌍" };
    await Promise.race([finish.promise, new Promise<void>(resolve => {
      if (request.signal.aborted) resolve();
      else request.signal.addEventListener("abort", () => resolve(), { once: true });
    })]);
    request.signal.throwIfAborted();
    yield { type: "done" };
  } });
  const conversation = await client.create("fake", root);
  const observer = client.events(conversation.id, AbortSignal.timeout(4000));
  assert.equal((await observer.next()).value?.type, "snapshot");
  let deltas = "";
  const observed = (async () => {
    for await (const frame of observer) {
      if (frame.type === "runtime" && frame.event.type === "text") {
        deltas += frame.event.delta;
        receivedText.release();
      }
      if (frame.snapshot?.operation?.state === "completed") return frame.snapshot;
    }
    throw new Error("Missing completion");
  })();
  await client.submit(conversation.id, "Stream now");
  await receivedText.promise;
  assert.equal(deltas, "Live 🌍");
  assert.equal((await client.get(conversation.id)).operation?.state, "running");
  finish.release();
  assert.equal((await observed).messages.at(-1)?.text, deltas);
});
