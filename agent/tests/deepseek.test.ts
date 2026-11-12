import assert from "node:assert/strict";
import { mkdtemp, readFile, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { Conversation } from "../src/core/conversation.ts";
import { ProviderFailure } from "../src/core/provider-failure.ts";
import type { Approval, ProviderEvent, ProviderRequest } from "../src/core/types.ts";
import { AgentManager } from "../src/manager/agent-manager.ts";
import { DeepSeekProvider } from "../src/providers/deepseek.ts";
import { JsonConversationStore } from "../src/storage/conversation-store.ts";
import { createWorkspaceTools } from "../src/tools/index.ts";

const key = "synthetic-test-key";
const model = "deepseek-flash";
const event = (value: unknown): string => `data: ${typeof value === "string" ? value : JSON.stringify(value)}\n\n`;
const delta = (value: unknown, finish: string | null = null) => ({ choices: [{ index: 0, delta: value, finish_reason: finish }] });
const call = (arguments_ = "{}", index = 0, id = "call-1") => delta({ tool_calls: [
  { index, id, type: "function", function: { name: "edit_file", arguments: arguments_ } },
] });
const complete = (text = "Done") => event(delta({ content: text })) + event(delta({}, "stop")) + event("[DONE]");

function response(wire: string | Uint8Array, chunkSize = 19, keepOpen = false) {
  const bytes = typeof wire === "string" ? new TextEncoder().encode(wire) : wire;
  let offset = 0, cancelled = false;
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (offset < bytes.length) {
        controller.enqueue(bytes.slice(offset, offset + chunkSize));
        offset += chunkSize;
      } else if (!keepOpen) controller.close();
    },
    cancel() { cancelled = true; },
  });
  return { value: new Response(body, { headers: { "Content-Type": "text/event-stream; charset=utf-8" } }),
    cancelled: () => cancelled };
}

function request(signal = new AbortController().signal): ProviderRequest {
  return { model, messages: [{ role: "user", text: "Hello" }], tools: [], signal };
}

async function collect(provider: DeepSeekProvider, input = request()): Promise<ProviderEvent[]> {
  const events: ProviderEvent[] = [];
  for await (const event of provider.stream(input)) events.push(event);
  return events;
}

function nextApproval(conversation: Conversation): Promise<Approval> {
  return new Promise(resolve => {
    const unsubscribe = conversation.subscribe(event => {
      if (event.type !== "approval" || !event.approvalID) return;
      unsubscribe(); resolve(conversation.snapshot().approval!);
    });
  });
}

function gate() {
  let release!: () => void;
  const promise = new Promise<void>(resolve => { release = resolve; });
  return { promise, release };
}

test("DeepSeek sends concrete non-thinking requests and decodes split UTF-8/SSE framing", async () => {
  const json = JSON.stringify(delta({ role: "assistant", content: "Hello λ 🥑" }));
  const split = json.indexOf("[");
  const wire = "\ufeff: keepalive\r\nretry: 1\r\n\r\n"
    + `data: ${json.slice(0, split)}\rdata: ${json.slice(split)}\r\r`
    + event(delta({}, "stop")) + event({ choices: [], usage: { total_tokens: 10 } }) + event("[DONE]");
  let requests = 0;
  const transport = response(wire, 1, true);
  const provider = new DeepSeekProvider({ getAPIKey: () => key, async fetch(url, init) {
    requests++;
    assert.equal(url, "https://api.deepseek.com/chat/completions");
    assert.equal(init.method, "POST");
    assert.equal(init.redirect, "error");
    assert.equal(new Headers(init.headers).get("authorization"), `Bearer ${key}`);
    assert.deepEqual(JSON.parse(String(init.body)), {
      model, stream: true, thinking: { type: "disabled" }, reasoning_effort: "none",
      messages: [{ role: "user", content: "Hello" }],
    });
    return transport.value;
  } });
  assert.deepEqual(await collect(provider), [{ type: "text", delta: "Hello λ 🥑" }, { type: "done" }]);
  assert.equal(requests, 1);
  assert.equal(transport.cancelled(), true);
});

test("fragmented tool calls are assembled by index and withheld until completion", async () => {
  const first = gate(), release = gate();
  const initial = event(delta({ tool_calls: [
    { index: 1, id: "second", type: "function", function: { name: "read_file", arguments: '{"path":' } },
    { index: 0, id: "first", type: "function", function: { name: "list_files", arguments: '{"path":"' } },
  ] }));
  let reads = 0;
  const body = new ReadableStream<Uint8Array>({
    async pull(controller) {
      if (reads++ === 0) { controller.enqueue(new TextEncoder().encode(initial)); first.release(); return; }
      await release.promise;
      controller.enqueue(new TextEncoder().encode(event(delta({ tool_calls: [
        { index: 0, function: { arguments: '."}' } },
        { index: 1, function: { arguments: '"x","start_line":1,"end_line":2}' } },
      ] }, "tool_calls")) + event("[DONE]")));
      controller.close();
    },
  });
  const provider = new DeepSeekProvider({ getAPIKey: () => key, fetch: async () => new Response(body, {
    headers: { "Content-Type": "text/event-stream" },
  }) });
  const seen: ProviderEvent[] = [];
  const collecting = (async () => { for await (const event of provider.stream(request())) seen.push(event); })();
  await first.promise;
  assert.deepEqual(seen, []);
  release.release(); await collecting;
  assert.deepEqual(seen, [
    { type: "tool_call", call: { id: "first", name: "list_files", arguments: { path: "." } } },
    { type: "tool_call", call: { id: "second", name: "read_file", arguments: { path: "x", start_line: 1, end_line: 2 } } },
    { type: "done" },
  ]);
});

test("incomplete, inconsistent, and unsupported responses cannot complete tool calls", async t => {
  const cases = [
    ["missing sentinel", event(call()) + event(delta({}, "tool_calls"))],
    ["missing finish", event(call()) + event("[DONE]")],
    ["output limit", event(call()) + event(delta({}, "length")) + event("[DONE]")],
    ["inconsistent stop", event(call()) + event(delta({}, "stop")) + event("[DONE]")],
    ["invalid arguments", event(call("[]")) + event(delta({}, "tool_calls")) + event("[DONE]")],
    ["nonfinite arguments", event(call('{"x":1e999}')) + event(delta({}, "tool_calls")) + event("[DONE]")],
    ["duplicate IDs", event(call("{}", 0, "same")) + event(call("{}", 1, "same")) + event(delta({}, "tool_calls")) + event("[DONE]")],
    ["missing index", event(call("{}", 1)) + event(delta({}, "tool_calls")) + event("[DONE]")],
    ["oversized arguments", event(call(JSON.stringify({ x: "x".repeat(32768) }))) + event(delta({}, "tool_calls")) + event("[DONE]")],
    ["malformed event", event("{malformed")],
    ["unexpected thinking", event(delta({ reasoning_content: "must not expose reasoning" }))],
  ];
  for (const [name, wire] of cases) await t.test(name!, async () => {
    let requests = 0;
    const provider = new DeepSeekProvider({ getAPIKey: () => key, async fetch() { requests++; return response(wire!, 4096).value; } });
    const seen: ProviderEvent[] = [];
    await assert.rejects(async () => {
      for await (const event of provider.stream(request())) seen.push(event);
    }, ProviderFailure);
    assert.equal(requests, 1);
    assert.equal(seen.some(event => event.type === "tool_call" || event.type === "done"), false);
  });
});

test("malformed UTF-8 and oversized SSE frames are bounded failures", async () => {
  for (const bytes of [Buffer.from([0xff]), Buffer.from(`data: ${"x".repeat(256 * 1024)}\n\n`)]) {
    const provider = new DeepSeekProvider({ getAPIKey: () => key, fetch: async () => response(bytes, 8192).value });
    await assert.rejects(collect(provider), error => error instanceof ProviderFailure && error.code === "response");
  }
});

test("HTTP failures are sanitized, bodies discarded, and requests never retried", async () => {
  for (const [status, code] of [[401, "authentication"], [402, "quota"], [429, "rate_limit"], [500, "transport"], [302, "transport"]] as const) {
    let requests = 0, cancelled = false;
    const provider = new DeepSeekProvider({ getAPIKey: () => key, async fetch() {
      requests++;
      return new Response(new ReadableStream({
        start(controller) { controller.enqueue(new TextEncoder().encode(`raw secret: ${key}`)); },
        cancel() { cancelled = true; },
      }), { status, headers: { "Content-Type": "application/json" } });
    } });
    await assert.rejects(collect(provider), error => {
      assert.ok(error instanceof ProviderFailure);
      assert.equal(error.code, code);
      assert.doesNotMatch(error.message, /raw secret|synthetic-test-key/);
      return true;
    });
    assert.equal(requests, 1);
    assert.equal(cancelled, true);
  }
});

test("credential and transport exceptions never enter runtime state verbatim", async () => {
  let requests = 0;
  const provider = new DeepSeekProvider({ getAPIKey() { throw new Error(`private credential ${key}`); },
    async fetch() { requests++; throw new Error("unreachable"); } });
  const conversation = new Conversation({ provider, model, workspace: "/test" });
  assert.equal((await conversation.submit("Hi").completion).state, "failed");
  assert.match(conversation.snapshot().operation!.error!, /authentication failed/);
  assert.doesNotMatch(JSON.stringify(conversation.snapshot()), /private credential|synthetic-test-key/);
  assert.equal(requests, 0);
  const network = new DeepSeekProvider({ getAPIKey: () => key, async fetch() { requests++; throw new Error(`raw request ${key}`); } });
  await assert.rejects(collect(network), error => error instanceof ProviderFailure && error.code === "transport" && !error.message.includes(key));
  assert.equal(requests, 1);
});

test("missing credentials and pre-cancellation send no HTTP request", async () => {
  let requests = 0, credentials = 0;
  const missing = new DeepSeekProvider({ getAPIKey: () => "", async fetch() { requests++; throw new Error("unreachable"); } });
  await assert.rejects(collect(missing), error => error instanceof ProviderFailure && error.code === "authentication");
  const cancelled = new AbortController(); cancelled.abort();
  const provider = new DeepSeekProvider({ getAPIKey() { credentials++; return key; },
    async fetch() { requests++; throw new Error("unreachable"); } });
  await assert.rejects(collect(provider, request(cancelled.signal)));
  assert.equal(requests, 0);
  assert.equal(credentials, 0);
});

test("timeouts cancel stalled response bodies without retrying", { timeout: 3000 }, async () => {
  const stream = response("", 19, true);
  let requests = 0;
  const provider = new DeepSeekProvider({ getAPIKey: () => key, timeoutMs: 30,
    async fetch() { requests++; return stream.value; } });
  await assert.rejects(collect(provider), error => error instanceof ProviderFailure && error.code === "timeout");
  assert.equal(requests, 1);
  assert.equal(stream.cancelled(), true);
});

test("cancellation before response headers aborts transport without retry", { timeout: 3000 }, async () => {
  const started = gate();
  const controller = new AbortController();
  let requests = 0, cancelled = false;
  const provider = new DeepSeekProvider({ getAPIKey: () => key, fetch: async (_url, init) => {
    requests++; started.release();
    return new Promise<Response>((_resolve, reject) => {
      init.signal!.addEventListener("abort", () => { cancelled = true; reject(init.signal!.reason); }, { once: true });
    });
  } });
  const rejected = assert.rejects(collect(provider, request(controller.signal)), { name: "AbortError" });
  await started.promise;
  controller.abort();
  await rejected;
  assert.equal(requests, 1);
  assert.equal(cancelled, true);
});

test("a credential result arriving after cancellation cannot start inference", async () => {
  const loading = gate(), release = gate();
  const controller = new AbortController();
  let requests = 0;
  const provider = new DeepSeekProvider({ async getAPIKey() { loading.release(); await release.promise; return key; },
    async fetch() { requests++; return response(complete()).value; } });
  const rejected = assert.rejects(collect(provider, request(controller.signal)), { name: "AbortError" });
  await loading.promise;
  controller.abort(); release.release();
  await rejected;
  assert.equal(requests, 0);
});

test("successful HTTP responses still require the expected body and content type", async () => {
  for (const value of [new Response(null), Response.json({ error: `raw secret ${key}` })]) {
    const provider = new DeepSeekProvider({ getAPIKey: () => key, fetch: async () => value });
    await assert.rejects(collect(provider), error => error instanceof ProviderFailure && error.code === "response" && !error.message.includes(key));
  }
});

test("a shared provider isolates concurrent conversation cancellation", { timeout: 3000 }, async () => {
  const started = gate();
  const slow = response(event(delta({ content: "Partial A" })), 4096, true);
  let requests = 0;
  const provider = new DeepSeekProvider({ getAPIKey: () => key, async fetch(_url, init) {
    requests++;
    const body = JSON.parse(String(init.body));
    return body.messages[0].content === "A" ? slow.value : response(complete("B completed")).value;
  } });
  const a = new Conversation({ provider, model, workspace: "/a" });
  const b = new Conversation({ provider, model, workspace: "/b" });
  a.subscribe(event => { if (event.type === "text") started.release(); });
  const first = a.submit("A"), second = b.submit("B");
  await started.promise;
  a.cancel(first.operationID);
  assert.equal((await first.completion).state, "interrupted");
  assert.equal((await second.completion).state, "completed");
  assert.equal(slow.cancelled(), true);
  assert.equal(requests, 2);
});

test("model discovery returns only bounded provider-neutral metadata", async () => {
  let requests = 0;
  const provider = new DeepSeekProvider({ getAPIKey: () => key, async fetch(url, init) {
    requests++;
    assert.equal(url, "https://api.deepseek.com/models");
    assert.equal(init.method, "GET");
    assert.equal(init.redirect, "error");
    assert.equal(init.body, undefined);
    return Response.json({ object: "list", data: [
      { id: model, name: "DeepSeek Flash", context_window: 1048576, max_output_tokens: 393216, owned_by: "not exported", effort: { supported_levels: ["high"] } },
      { id: "deepseek-v4-pro" },
    ] });
  } });
  assert.deepEqual(await provider.models(new AbortController().signal), [
    { id: model, name: "DeepSeek Flash", contextWindow: 1048576, maxOutputTokens: 393216 },
    { id: "deepseek-v4-pro", name: "deepseek-v4-pro" },
  ]);
  assert.equal(requests, 1);
  const duplicate = new DeepSeekProvider({ getAPIKey: () => key, fetch: async () => Response.json({ object: "list", data: [{ id: model }, { id: model }] }) });
  await assert.rejects(duplicate.models(new AbortController().signal), ProviderFailure);
});

test("DeepSeek-shaped HTTP responses drive approved real tools and durable continuation", { timeout: 10000 }, async t => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "exec-deepseek-")));
  t.after(() => rm(root, { recursive: true, force: true }));
  const profile = join(root, "profile");
  const requests: Record<string, unknown>[] = [];
  const provider = new DeepSeekProvider({ getAPIKey: () => key, async fetch(_url, init) {
    const body = JSON.parse(String(init.body));
    requests.push(body);
    if (requests.length === 1) return response(event(call(JSON.stringify({
      path: "result.txt", expected_revision: "new", old_text: "", new_text: "approved content",
    }))) + event(delta({}, "tool_calls")) + event("[DONE]")).value;
    return response(complete("File created")).value;
  } });
  const tools = createWorkspaceTools();
  const manager = await AgentManager.open(await JsonConversationStore.open(profile), () => ({ provider, tools }));
  const conversation = await manager.create({ provider, model, workspace: root, tools });
  const pending = nextApproval(conversation);
  const run = conversation.submit("Create result.txt");
  const approval = await pending;
  await assert.rejects(readFile(join(root, "result.txt")), { code: "ENOENT" });
  assert.equal(requests.length, 1);
  conversation.resolveApproval(run.operationID, approval.id, true);
  assert.equal((await run.completion).state, "completed");
  assert.equal(await readFile(join(root, "result.txt"), "utf8"), "approved content");
  assert.equal(requests.length, 2);
  const messages = requests[1]!.messages as Record<string, unknown>[];
  assert.equal(messages[1]!.role, "assistant");
  assert.equal(messages[2]!.role, "tool");
  assert.equal(messages[2]!.tool_call_id, "call-1");
  assert.match(String(messages[2]!.content), /Edited/);
  assert.ok(Array.isArray(requests[0]!.tools));
  assert.doesNotMatch(JSON.stringify(conversation.snapshot()), /synthetic-test-key/);
  await manager.close();
  const persisted = await readFile(join(profile, `${conversation.id}.json`), "utf8");
  assert.doesNotMatch(persisted, /synthetic-test-key|Authorization/);
  const restored = await AgentManager.open(await JsonConversationStore.open(profile), () => ({ provider, tools }));
  assert.equal(requests.length, 2); // Reopening did not infer or execute.
  await restored.get(conversation.id).submit("Continue").completion;
  assert.equal(requests.length, 3);
  assert.equal((requests[2]!.messages as unknown[]).length, 5);
  await restored.close();
});

test("tool failure outcomes remain explicit in DeepSeek wire context", async () => {
  const input = request();
  input.messages = [
    { role: "user", text: "Change" },
    { role: "assistant", text: "", calls: [{ id: "a", name: "edit_file", arguments: { path: "x" } }] },
    { role: "tool", callID: "a", text: "May have had effects", outcome: "interrupted" },
    { role: "user", text: "Inspect instead" },
  ];
  const provider = new DeepSeekProvider({ getAPIKey: () => key, async fetch(_url, init) {
    const body = JSON.parse(String(init.body));
    assert.equal(body.messages[1].tool_calls[0].function.arguments, '{"path":"x"}');
    assert.match(body.messages[2].content, /Tool outcome: interrupted/);
    assert.match(body.messages[2].content, /May have had effects/);
    return response(complete()).value;
  } });
  await collect(provider, input);
});
