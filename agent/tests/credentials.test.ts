import assert from "node:assert/strict";
import { spawn, execFile } from "node:child_process";
import { once } from "node:events";
import { chmod, mkdtemp, readFile, readdir, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import test, { type TestContext } from "node:test";
import { AgentClient } from "../src/client/agent-client.ts";
import { configuredDeepSeekProvider, loadDeepSeekAPIKey } from "../src/providers/credentials.ts";

const cli = fileURLToPath(new URL("../src/entrypoints/cli.ts", import.meta.url));
const secret = "test-only-credential";
async function directory(t: TestContext) {
  const root = await mkdtemp(join(tmpdir(), "ec-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  return root;
}
async function credentials(root: string, content = JSON.stringify({ deepseek: { apiKey: secret } })) {
  const path = join(root, "credentials.json");
  await writeFile(path, content, { mode: 0o600 });
  return path;
}

test("credentials load private JSON, custom paths, and environment overrides without writing", async t => {
  const profile = await directory(t);
  const path = await credentials(profile);
  assert.equal(await loadDeepSeekAPIKey({ profile, env: {} }), secret);
  assert.equal(await loadDeepSeekAPIKey({ profile: join(profile, "unused"), credentialsPath: path, env: {} }), secret);
  // Environment takes precedence without even reading an invalid file.
  await writeFile(path, "invalid " + secret);
  assert.equal(await loadDeepSeekAPIKey({ profile, env: { DEEPSEEK_API_KEY: " override " } }), "override");
  assert.equal(await readFile(path, "utf8"), "invalid " + secret);
});

for (const value of ["", " ", "bad\nkey", "bad key", "é", "x".repeat(8193)]) {
  test(`invalid environment credentials fail closed (${JSON.stringify(value.slice(0, 12))})`, async () => {
    await assert.rejects(loadDeepSeekAPIKey({ profile: "/not-consulted", env: { DEEPSEEK_API_KEY: value } }), /Invalid DeepSeek API key/);
  });
}

test("missing, malformed, oversized, and unknown JSON credentials fail with redacted errors", async t => {
  const profile = await directory(t);
  const safeError = (error: unknown) => error instanceof Error
    && error.message.startsWith("Cannot load DeepSeek credentials.") && !error.message.includes(secret)
    && !error.message.includes(profile);
  await assert.rejects(loadDeepSeekAPIKey({ profile, env: {} }), safeError);
  for (const content of [secret, `{"${secret}":`, "null", "[]", "{}", JSON.stringify({ deepseek: { apiKey: "" } }),
    JSON.stringify({ deepseek: { apiKey: secret, unknown: secret } }), JSON.stringify({ deepseek: { apiKey: secret }, extra: true }),
    JSON.stringify({ deepseek: { apiKey: 123 } }), " ".repeat(16385)]) {
    await credentials(profile, content);
    await assert.rejects(loadDeepSeekAPIKey({ profile, env: {} }), safeError);
  }
});

test("credential files reject shared permissions, symlinks, and directories without changing them", async t => {
  const profile = await directory(t);
  const path = await credentials(profile);
  await chmod(path, 0o644);
  await assert.rejects(loadDeepSeekAPIKey({ profile, env: {} }), /Cannot load/);
  assert.equal((await stat(path)).mode & 0o777, 0o644);
  await chmod(path, 0o600);
  const link = join(profile, "link.json");
  await symlink(path, link);
  await assert.rejects(loadDeepSeekAPIKey({ profile, credentialsPath: link, env: {} }), /Cannot load/);
  await assert.rejects(loadDeepSeekAPIKey({ profile, credentialsPath: profile, env: {} }), /Cannot load/);
});

test("configured provider uses credentials only for provider transport", async t => {
  const profile = await directory(t);
  const previousFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async (url, init) => {
    calls++;
    assert.equal(url, "https://api.deepseek.com/models");
    assert.equal(new Headers(init?.headers).get("Authorization"), `Bearer ${secret}`);
    return Response.json({ object: "list", data: [{ id: "deepseek-chat" }] });
  };
  t.after(() => { globalThis.fetch = previousFetch; });
  const provider = await configuredDeepSeekProvider({ profile, env: { DEEPSEEK_API_KEY: secret } });
  assert.equal(calls, 0, "configuration never discovers models or performs inference");
  const models = await provider.models!(new AbortController().signal);
  assert.equal(models[0]?.id, "deepseek-chat");
  assert.equal(calls, 1);
});

async function start(t: TestContext, profile: string, args: string[], env: NodeJS.ProcessEnv) {
  const child = spawn(process.execPath, [cli, "--profile", profile, "serve", ...args], {
    env, stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  child.stdout.on("data", data => { output += data; });
  child.stderr.on("data", data => { output += data; });
  const exited = once(child, "exit");
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) { child.kill("SIGTERM"); await exited; }
    assert.equal(output.includes(secret), false);
  });
  const client = new AgentClient(join(profile, "service.sock"));
  for (let attempt = 0; attempt < 200; attempt++) {
    if (child.exitCode !== null || child.signalCode !== null) throw new Error("Service exited before startup: " + output);
    try { await client.health(); return { child, client, exited }; }
    catch { await new Promise(resolve => setTimeout(resolve, 20)); }
  }
  throw new Error("Service startup timed out.");
}

test("standalone serve loads JSON/env, cleans shutdown, and reopens durable state without exposing credentials", { timeout: 15000 }, async t => {
  const root = await directory(t);
  const profile = join(root, "profile");
  const path = await credentials(root);
  const first = await start(t, profile, ["--credentials", path], {});
  assert.deepEqual(await first.client.health(), { version: 1, toolsEnabled: false });
  const conversation = await first.client.create("deepseek-chat", root);
  assert.equal(JSON.stringify(await first.client.get(conversation.id)).includes(secret), false);
  const disk = await readFile(join(profile, "conversations", `${conversation.id}.json`), "utf8");
  assert.equal(disk.includes(secret), false);
  first.child.kill("SIGTERM");
  assert.deepEqual(await first.exited, [0, null]);
  assert.equal((await readdir(profile)).includes("service.sock"), false);
  assert.equal((await readdir(join(profile, "conversations"))).includes(".lock"), false);
  const second = await start(t, profile, ["--workspace-tools"], { DEEPSEEK_API_KEY: secret });
  assert.deepEqual(await second.client.health(), { version: 1, toolsEnabled: true });
  assert.equal((await second.client.list())[0]?.id, conversation.id);
  second.child.kill("SIGINT");
  assert.deepEqual(await second.exited, [0, null]);
  await credentials(profile);
  const third = await start(t, profile, [], {});
  assert.equal((await third.client.list())[0]?.id, conversation.id);
  third.child.kill("SIGTERM");
  assert.deepEqual(await third.exited, [0, null]);
});

test("serve fails before creating profile on missing credentials or invalid arguments", async t => {
  const root = await directory(t);
  const profile = join(root, "absent");
  for (const args of [[], ["--credentials"], ["--api-key", secret], ["--workspace-tools", "--workspace-tools"]]) {
    await assert.rejects(promisify(execFile)(process.execPath, [cli, "--profile", profile, "serve", ...args], { env: {} }),
      (error: unknown) => {
        const result = error as { stderr: string; stdout: string; code: number };
        assert.equal(result.code, 1);
        assert.equal((result.stderr + result.stdout).includes(secret), false);
        return true;
      });
  }
  await assert.rejects(stat(profile), { code: "ENOENT" });
});
