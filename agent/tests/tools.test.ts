import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, readdir, realpath, rm, stat, symlink, writeFile, chmod } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import test, { type TestContext } from "node:test";
import { Conversation } from "../src/core/conversation.ts";
import type { Approval, ChatProvider, Json, ProviderRequest } from "../src/core/types.ts";
import { createWorkspaceTools } from "../src/tools/index.ts";
import { OUTPUT_LIMIT, revision } from "../src/tools/workspace.ts";

async function workspace(t: TestContext): Promise<string> {
  const root = await realpath(await mkdtemp(join(tmpdir(), "exec-agent-tools-")));
  t.after(() => rm(root, { recursive: true, force: true }));
  return root;
}

async function prepare(root: string, name: string, args: { [key: string]: Json }, signal = new AbortController().signal) {
  const tool = createWorkspaceTools().find(tool => tool.definition.name === name)!;
  return tool.prepare(args, { workspace: root, signal });
}

async function execute(root: string, name: string, args: { [key: string]: Json }) {
  return (await prepare(root, name, args)).execute();
}

function edit(path: string, before: string, after: string) {
  return { path, expected_revision: revision(Buffer.from(before)), old_text: before, new_text: after };
}

function nextApproval(conversation: Conversation): Promise<Approval> {
  return new Promise(resolve => {
    const unsubscribe = conversation.subscribe(event => {
      if (event.type !== "approval" || !event.approvalID) return;
      unsubscribe();
      resolve(conversation.snapshot().approval!);
    });
  });
}

const quote = (value: string): string => `'${value.replaceAll("'", "'\\''")}'`;
const node = (script: string): string => `${quote(process.execPath)} -e ${quote(script)}`;

async function waitForFile(path: string): Promise<string> {
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline) {
    try { return await readFile(path, "utf8"); }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
    await delay(10);
  }
  throw new Error("Test child did not become ready.");
}

test("file reads return full revisions, preserve UTF-8, and bound output", async t => {
  const root = await workspace(t);
  const content = "\ufeffHello λ\nsecond line\n";
  await writeFile(join(root, "sample.txt"), content);
  const prepared = await prepare(root, "read_file", { path: "sample.txt", start_line: 2, end_line: 2 });
  assert.equal(prepared.approval, null);
  assert.equal(await prepared.execute(), `Revision: ${revision(Buffer.from(content))}\n2: second line\n`);
  await writeFile(join(root, "long.txt"), "x".repeat(50000));
  const output = await execute(root, "read_file", { path: "long.txt", start_line: 1, end_line: 1 });
  assert.ok(Buffer.byteLength(output) <= OUTPUT_LIMIT);
  assert.match(output, /truncated/);
  await assert.rejects(prepare(root, "read_file", { path: "sample.txt", start_line: 1, end_line: 401 }), /end_line/);
});

test("file tools reject traversal, symlinks, binary, and oversized input", async t => {
  const root = await workspace(t);
  const outside = await workspace(t);
  await writeFile(join(outside, "secret.txt"), "outside");
  await symlink(outside, join(root, "linked"));
  await symlink(join(outside, "secret.txt"), join(root, "file-link"));
  await writeFile(join(root, "binary"), Buffer.from([0, 1]));
  await writeFile(join(root, "invalid-utf8"), Buffer.from([0xff]));
  await writeFile(join(root, "large"), Buffer.alloc(1024 * 1024 + 1, 65));
  for (const path of ["../secret.txt", join(outside, "secret.txt"), "linked/secret.txt", "file-link", "binary", "invalid-utf8", "large"]) {
    await assert.rejects(execute(root, "read_file", { path, start_line: 1, end_line: 10 }));
  }
  const listing = await execute(root, "list_files", { path: "." });
  assert.match(listing, /symlink; not followed/);
  await assert.rejects(execute(root, "list_files", { path: "linked" }));
});

test("search is literal and excludes hidden/build/linked files", async t => {
  const root = await workspace(t);
  await mkdir(join(root, "src"));
  await mkdir(join(root, "node_modules"));
  await writeFile(join(root, "src", "main.txt"), "needle.*\nNEEDLE.*\n");
  await writeFile(join(root, ".hidden"), "needle.* hidden");
  await writeFile(join(root, "node_modules", "dep.txt"), "needle.* dependency");
  await symlink(join(root, "src"), join(root, "linked"));
  const output = await execute(root, "search_text", { path: ".", query: "needle.*" });
  assert.match(output, /src\/main.txt.*:1: needle\.\*/);
  assert.doesNotMatch(output, /hidden|dependency|:2:/);
  assert.match(output, /Search incomplete/);
  await assert.rejects(prepare(root, "search_text", { path: ".", query: "" }));
});

test("edit prepares without writing, applies exact text, and preserves ordinary mode", async t => {
  const root = await workspace(t);
  const path = join(root, "script");
  const before = "\ufefffirst\nsecond\n";
  await writeFile(path, before);
  await chmod(path, 0o750);
  const prepared = await prepare(root, "edit_file", {
    path: "script", expected_revision: revision(Buffer.from(before)), old_text: "second", new_text: "changed",
  });
  assert.match(prepared.approval!, /Replace exact text/);
  assert.equal(await readFile(path, "utf8"), before);
  const output = await prepared.execute();
  assert.equal(await readFile(path, "utf8"), "\ufefffirst\nchanged\n");
  assert.match(output, /Revision:/);
  assert.equal((await stat(path)).mode & 0o777, 0o750);
  assert.deepEqual(await readdir(root), ["script"]);
});

test("stale and nonunique edits fail without overwriting or staging leftovers", async t => {
  const root = await workspace(t);
  const path = join(root, "file");
  await writeFile(path, "aaa");
  await assert.rejects(prepare(root, "edit_file", {
    path: "file", expected_revision: revision(Buffer.from("aaa")), old_text: "aa", new_text: "b",
  }), /exactly once/);
  await assert.rejects(prepare(root, "edit_file", edit("file", "wrong", "new")), /Revision mismatch/);
  const prepared = await prepare(root, "edit_file", edit("file", "aaa", "approved"));
  await writeFile(path, "external change");
  await assert.rejects(prepared.execute(), /changed while approval/);
  assert.equal(await readFile(path, "utf8"), "external change");
  assert.deepEqual(await readdir(root), ["file"]);
});

test("concurrent edits serialize final checks and only one revision wins", async t => {
  const root = await workspace(t);
  await writeFile(join(root, "file"), "original");
  const a = await prepare(root, "edit_file", edit("file", "original", "first"));
  const b = await prepare(root, "edit_file", edit("file", "original", "second"));
  const results = await Promise.allSettled([a.execute(), b.execute()]);
  assert.deepEqual(results.map(result => result.status), ["fulfilled", "rejected"]);
  assert.equal(await readFile(join(root, "file"), "utf8"), "first");
  assert.deepEqual(await readdir(root), ["file"]);
});

test("creation never overwrites a competing creator and cancellation does not write", async t => {
  const root = await workspace(t);
  const args = { path: "new.txt", expected_revision: "new", old_text: "", new_text: "new content" };
  const prepared = await prepare(root, "edit_file", args);
  await writeFile(join(root, "new.txt"), "competitor");
  await assert.rejects(prepared.execute(), /no longer available/);
  assert.equal(await readFile(join(root, "new.txt"), "utf8"), "competitor");
  const controller = new AbortController();
  const cancelled = await prepare(root, "edit_file", { ...args, path: "cancelled" }, controller.signal);
  controller.abort();
  await assert.rejects(cancelled.execute());
  assert.deepEqual(await readdir(root), ["new.txt"]);
  await execute(root, "edit_file", { ...args, path: "created" });
  assert.equal(await readFile(join(root, "created"), "utf8"), "new content");
});

test("an ancestor replaced by a symlink during approval is refused", async t => {
  const root = await workspace(t);
  const outside = await workspace(t);
  await mkdir(join(root, "nested"));
  await writeFile(join(root, "nested", "file"), "original");
  await writeFile(join(outside, "file"), "outside");
  const prepared = await prepare(root, "edit_file", edit("nested/file", "original", "new"));
  await rm(join(root, "nested"), { recursive: true });
  await symlink(outside, join(root, "nested"));
  await assert.rejects(prepared.execute(), /Symlinks/);
  assert.equal(await readFile(join(outside, "file"), "utf8"), "outside");
});

test("a stale approved edit becomes an actionable runtime tool failure without effects", { timeout: 5000 }, async t => {
  const root = await workspace(t);
  await writeFile(join(root, "file"), "original");
  let requests = 0;
  const provider: ChatProvider = {
    async *stream(_request: ProviderRequest) {
      if (requests++ === 0) yield { type: "tool_call", call: { id: "edit", name: "edit_file", arguments: edit("file", "original", "new") } };
      yield { type: "done" };
    },
  };
  const conversation = new Conversation({ provider, model: "fake", workspace: root, tools: createWorkspaceTools() });
  const pending = nextApproval(conversation);
  const run = conversation.submit("Edit");
  const approval = await pending;
  await writeFile(join(root, "file"), "external change");
  conversation.resolveApproval(run.operationID, approval.id, true);
  await run.completion;
  const result = conversation.snapshot().messages.find(row => row.role === "tool");
  assert.ok(result?.role === "tool");
  assert.equal(result.outcome, "failed");
  assert.match(result.text, /changed while approval/);
  assert.equal(await readFile(join(root, "file"), "utf8"), "external change");
});

test("shell requires approval, uses workspace, combines output, and reports exit errors", async t => {
  const root = await workspace(t);
  const prepared = await prepare(root, "shell", { command: "pwd; printf 'out'; printf 'err' >&2", timeout_seconds: 3 });
  assert.match(prepared.approval!, /Timeout: 3 seconds/);
  assert.match(prepared.approval!, /pwd;/);
  const output = await prepared.execute();
  assert.match(output, /Exit code: 0/);
  assert.ok(output.includes(root));
  assert.match(output, /out/);
  assert.match(output, /err/);
  await assert.rejects(execute(root, "shell", { command: "printf 'failed output'; exit 7" }), /Exit code: 7.*[\s\S]*failed output/);
});

test("shell does not inherit application secrets or startup injection variables", async t => {
  const root = await workspace(t);
  const keys = ["EXEC_TOOL_TEST_SECRET", "BASH_ENV"] as const;
  const previous = keys.map(key => process.env[key]);
  t.after(() => keys.forEach((key, index) => {
    if (previous[index] === undefined) delete process.env[key]; else process.env[key] = previous[index];
  }));
  process.env.EXEC_TOOL_TEST_SECRET = "synthetic-test-value";
  const startup = join(root, "startup.sh");
  await writeFile(startup, "printf injected");
  process.env.BASH_ENV = startup;
  const output = await execute(root, "shell", { command: "printf '%s' \"${EXEC_TOOL_TEST_SECRET-unset}\"" });
  assert.match(output, /unset/);
  assert.doesNotMatch(output, /synthetic-test-value|injected/);
});

test("shell bounds large output while continuing to drain pipes", async t => {
  const root = await workspace(t);
  const output = await execute(root, "shell", { command: node("process.stdout.write('first\\n' + 'x'.repeat(200000) + '\\nlast')") });
  assert.ok(Buffer.byteLength(output) <= OUTPUT_LIMIT);
  assert.match(output, /first/);
  assert.match(output, /last/);
  assert.match(output, /Output truncated/);
});

test("shell timeout terminates the invocation and retains bounded diagnostics", { timeout: 6000 }, async t => {
  const root = await workspace(t);
  const started = Date.now();
  await assert.rejects(execute(root, "shell", { command: "printf started; sleep 30", timeout_seconds: 1 }), /timed out.*[\s\S]*started/);
  assert.ok(Date.now() - started < 4000);
});

test("shell cancellation cleans up a process group, including a TERM-resistant child", { timeout: 8000 }, async t => {
  const root = await workspace(t);
  const controller = new AbortController();
  const script = "trap '' TERM; sleep 30 & child=$!; printf '%s' \"$child\" > child.pid; wait";
  const prepared = await prepare(root, "shell", { command: script, timeout_seconds: 5 }, controller.signal);
  const execution = prepared.execute();
  // Attach the rejection handler immediately so cancellation cannot be unhandled.
  const rejected = assert.rejects(execution, /interrupted/);
  t.after(() => controller.abort());
  const pid = Number(await waitForFile(join(root, "child.pid")));
  t.after(() => { try { process.kill(pid, "SIGKILL"); } catch { /* Already reaped. */ } });
  controller.abort();
  await rejected;
  // On Linux a killed orphan can remain a zombie until init reaps it. ps status
  // distinguishes that from a still-running process without treating zombies as work.
  const status = await execute(root, "shell", { command: `ps -o stat= -p ${pid} || true` });
  const state = status.split("\n").slice(1).join("\n").trim();
  assert.ok(state === "(no output)" || state === "" || state.startsWith("Z"), `Child still running: ${state}`);
});

test("real shell cancellation retains diagnostics and does not continue inference", { timeout: 8000 }, async t => {
  const root = await workspace(t);
  let requests = 0;
  const provider: ChatProvider = {
    async *stream() {
      requests++;
      yield { type: "tool_call" as const, call: { id: "shell", name: "shell", arguments: {
        command: "printf started; printf ready > ready; sleep 30", timeout_seconds: 5,
      } } };
      yield { type: "done" as const };
    },
  };
  const conversation = new Conversation({ provider, model: "fake", workspace: root, tools: createWorkspaceTools() });
  const pending = nextApproval(conversation);
  const run = conversation.submit("Run");
  t.after(() => conversation.cancel(run.operationID));
  const approval = await pending;
  conversation.resolveApproval(run.operationID, approval.id, true);
  await waitForFile(join(root, "ready"));
  conversation.cancel(run.operationID);
  assert.equal((await run.completion).state, "interrupted");
  assert.equal(requests, 1);
  const result = conversation.snapshot().messages.find(row => row.role === "tool");
  assert.ok(result?.role === "tool");
  assert.equal(result.outcome, "interrupted");
  assert.match(result.text, /started/);
  assert.match(result.text, /may have had effects/);
});

test("runtime denial never starts a real shell command", { timeout: 5000 }, async t => {
  const root = await workspace(t);
  let requests = 0;
  const provider: ChatProvider = {
    async *stream() {
      if (requests++ === 0) yield { type: "tool_call", call: { id: "shell", name: "shell", arguments: { command: "touch must-not-exist" } } };
      yield { type: "done" };
    },
  };
  const conversation = new Conversation({ provider, model: "fake", workspace: root, tools: createWorkspaceTools() });
  const pending = nextApproval(conversation);
  const run = conversation.submit("Run");
  const approval = await pending;
  conversation.resolveApproval(run.operationID, approval.id, false);
  await run.completion;
  assert.deepEqual(await readdir(root), []);
  const result = conversation.snapshot().messages.find(row => row.role === "tool");
  assert.ok(result?.role === "tool");
  assert.equal(result.outcome, "denied");
});
