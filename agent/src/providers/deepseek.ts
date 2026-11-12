import { ProviderFailure } from "../core/provider-failure.ts";
import type { ChatModel, ChatProvider, ProviderEvent, ProviderRequest, ToolCall } from "../core/types.ts";
import { readJSON, readSSE } from "./response-stream.ts";

type Transport = (url: string, init: RequestInit) => Promise<Response>;
interface Options {
  getAPIKey(signal: AbortSignal): string | Promise<string>;
  fetch?: Transport;
  timeoutMs?: number;
}

function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new ProviderFailure("response");
  return value as Record<string, unknown>;
}
function optionalText(value: unknown): string {
  if (value === undefined || value === null) return "";
  if (typeof value !== "string") throw new ProviderFailure("response");
  return value;
}
function checkJSON(value: unknown, depth = 0): void {
  if (depth > 64 || (typeof value === "number" && !Number.isFinite(value))) throw new ProviderFailure("response");
  if (value !== null && typeof value === "object") {
    for (const child of Object.values(value)) checkJSON(child, depth + 1);
  }
}
const validModel = (value: unknown): value is string => typeof value === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(value);
const validTool = (value: string): boolean => /^[A-Za-z0-9_-]{1,128}$/.test(value);

class Decoder {
  private readonly calls = new Map<number, { id: string; name: string; arguments: string; argumentBytes: number }>();
  private finish: "stop" | "tool_calls" | null = null;
  private textBytes = 0;
  private hasText = false;

  decode(data: string): ProviderEvent[] {
    if (data === "[DONE]") {
      if (!this.finish || (!this.hasText && !this.calls.size)
        || (this.finish === "tool_calls") !== (this.calls.size > 0)) throw new ProviderFailure("response");
      const ids = new Set<string>();
      const calls: ToolCall[] = [...this.calls].sort(([a], [b]) => a - b).map(([index, call], position) => {
        if (index !== position || !call.id.trim() || ids.has(call.id) || !validTool(call.name)) throw new ProviderFailure("response");
        ids.add(call.id);
        let args: unknown;
        try { args = JSON.parse(call.arguments); } catch { throw new ProviderFailure("response"); }
        object(args);
        checkJSON(args);
        return { id: call.id, name: call.name, arguments: args as ToolCall["arguments"] };
      });
      // Validate the whole batch before exposing any executable call.
      return [...calls.map(call => ({ type: "tool_call" as const, call })), { type: "done" }];
    }
    let value: unknown;
    try { value = JSON.parse(data); } catch { throw new ProviderFailure("response"); }
    const chunk = object(value);
    if (chunk.error != null || !Array.isArray(chunk.choices) || chunk.choices.length > 1) throw new ProviderFailure("response");
    if (chunk.choices.length === 0) {
      // Older endpoints can send a terminal usage-only chunk. Do not interpret it
      // as completion, and do not publish raw account/provider metadata.
      if (!this.finish) throw new ProviderFailure("response");
      object(chunk.usage);
      return [];
    }
    const choice = object(chunk.choices[0]);
    if (choice.index !== 0 || this.finish !== null) throw new ProviderFailure("response");
    const delta = object(choice.delta);
    if (delta.role !== undefined && delta.role !== "assistant") throw new ProviderFailure("response");
    if (optionalText(delta.reasoning_content)) throw new ProviderFailure("unsupported");
    const content = optionalText(delta.content);
    this.textBytes += Buffer.byteLength(content);
    if (this.textBytes > 4 * 1024 * 1024) throw new ProviderFailure("response");
    this.hasText ||= content.trim().length > 0;
    if (delta.tool_calls != null) {
      if (!Array.isArray(delta.tool_calls)) throw new ProviderFailure("response");
      for (const value of delta.tool_calls) {
        const fragment = object(value);
        if (typeof fragment.index !== "number" || !Number.isInteger(fragment.index)
          || fragment.index < 0 || fragment.index >= 64
          || (fragment.type != null && fragment.type !== "function")) throw new ProviderFailure("response");
        const call = this.calls.get(fragment.index) ?? { id: "", name: "", arguments: "", argumentBytes: 0 };
        call.id += optionalText(fragment.id);
        if (fragment.function != null) {
          const fn = object(fragment.function);
          call.name += optionalText(fn.name);
          const arguments_ = optionalText(fn.arguments);
          call.argumentBytes += Buffer.byteLength(arguments_);
          if (call.argumentBytes > 32768) throw new ProviderFailure("response");
          call.arguments += arguments_;
        }
        if (Buffer.byteLength(call.id) > 256 || Buffer.byteLength(call.name) > 128) throw new ProviderFailure("response");
        this.calls.set(fragment.index, call);
      }
    }
    if (choice.finish_reason != null) {
      if (choice.finish_reason !== "stop" && choice.finish_reason !== "tool_calls") throw new ProviderFailure("response");
      this.finish = choice.finish_reason;
    }
    return content ? [{ type: "text", delta: content }] : [];
  }
}

function requestBody(request: ProviderRequest): string {
  if (!validModel(request.model) || !request.messages.length || request.tools.length > 64) throw new ProviderFailure("request");
  const names = new Set<string>();
  for (const tool of request.tools) {
    if (!validTool(tool.name) || names.has(tool.name)) throw new ProviderFailure("request");
    names.add(tool.name);
  }
  try {
    const body = JSON.stringify({
      model: request.model, stream: true,
      // DeepSeek currently defaults to thinking. Until opaque reasoning context
      // is supported, explicitly request non-thinking rather than dropping it.
      thinking: { type: "disabled" }, reasoning_effort: "none",
      messages: request.messages.map(message => {
        if (message.role === "user") return { role: "user", content: message.text };
        if (message.role === "tool") return { role: "tool", tool_call_id: message.callID,
          content: message.outcome === "completed" ? message.text : `[Tool outcome: ${message.outcome}]\n${message.text}` };
        return { role: "assistant", content: message.text,
          ...(message.calls.length ? { tool_calls: message.calls.map(call => ({ id: call.id, type: "function",
            function: { name: call.name, arguments: JSON.stringify(call.arguments) } })) } : {}) };
      }),
      ...(request.tools.length ? { tools: request.tools.map(tool => ({ type: "function", function: {
        name: tool.name, description: tool.description, parameters: tool.parameters,
      } })) } : {}),
    });
    if (Buffer.byteLength(body) > 16 * 1024 * 1024) throw new ProviderFailure("request");
    return body;
  } catch { throw new ProviderFailure("request"); }
}

// A concrete, stateless DeepSeek implementation. It can be shared by independent
// conversations; each request owns its decoder, response body, timeout and signal.
export class DeepSeekProvider implements ChatProvider {
  private readonly getAPIKey: Options["getAPIKey"];
  private readonly transport: Transport;
  private readonly timeoutMs: number;

  constructor(options: Options) {
    this.getAPIKey = options.getAPIKey;
    this.transport = options.fetch ?? globalThis.fetch;
    this.timeoutMs = options.timeoutMs ?? 120000;
    if (!Number.isSafeInteger(this.timeoutMs) || this.timeoutMs < 1 || this.timeoutMs > 900000) throw new ProviderFailure("request");
  }

  private scope(signal: AbortSignal) {
    signal.throwIfAborted();
    const deadline = new AbortController();
    const timer = setTimeout(() => deadline.abort(), this.timeoutMs);
    return { signal: AbortSignal.any([signal, deadline.signal]),
      expired: () => deadline.signal.aborted, close: () => clearTimeout(timer) };
  }

  private async request(path: "chat/completions" | "models", signal: AbortSignal, body?: string): Promise<Response> {
    signal.throwIfAborted();
    let key: string;
    try { key = (await this.getAPIKey(signal)).trim(); }
    catch { signal.throwIfAborted(); throw new ProviderFailure("authentication"); }
    signal.throwIfAborted();
    if (!key || key.length > 8192 || /[^\x21-\x7e]/.test(key)) throw new ProviderFailure("authentication");
    const response = await this.transport(`https://api.deepseek.com/${path}`, {
      method: body === undefined ? "GET" : "POST", redirect: "error", credentials: "omit", cache: "no-store", signal,
      headers: { Authorization: `Bearer ${key}`, Accept: body === undefined ? "application/json" : "text/event-stream",
        ...(body === undefined ? {} : { "Content-Type": "application/json" }) },
      ...(body === undefined ? {} : { body }),
    });
    if (!response.ok) {
      await response.body?.cancel().catch(() => {});
      const status = response.status;
      throw new ProviderFailure(status === 401 || status === 403 ? "authentication"
        : status === 402 ? "quota" : status === 429 ? "rate_limit"
        : status === 408 || status === 504 ? "timeout"
        : status >= 400 && status < 500 ? "request" : "transport");
    }
    if (!response.body) throw new ProviderFailure("response");
    return response;
  }

  async *stream(request: ProviderRequest): AsyncGenerator<ProviderEvent> {
    const body = requestBody(request);
    const scope = this.scope(request.signal);
    let response: Response | undefined;
    try {
      response = await this.request("chat/completions", scope.signal, body);
      if (response.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase() !== "text/event-stream") {
        throw new ProviderFailure("response");
      }
      const decoder = new Decoder();
      for await (const data of readSSE(response.body!, scope.signal)) {
        scope.signal.throwIfAborted();
        const events = decoder.decode(data);
        for (const event of events) {
          scope.signal.throwIfAborted();
          yield event;
          if (event.type === "done") return;
        }
      }
      throw new ProviderFailure("response"); // EOF alone is never successful completion.
    } catch (error) {
      request.signal.throwIfAborted();
      if (scope.expired()) throw new ProviderFailure("timeout");
      throw error instanceof ProviderFailure ? error : new ProviderFailure("transport");
    } finally {
      scope.close();
      if (response?.body && !response.body.locked) await response.body.cancel().catch(() => {});
    }
  }

  async models(signal: AbortSignal): Promise<ChatModel[]> {
    const scope = this.scope(signal);
    let response: Response | undefined;
    try {
      response = await this.request("models", scope.signal);
      if (response.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase() !== "application/json") throw new ProviderFailure("response");
      const result = object(await readJSON(response.body!, scope.signal));
      scope.signal.throwIfAborted();
      if (result.object !== "list" || !Array.isArray(result.data) || result.data.length > 256) throw new ProviderFailure("response");
      const ids = new Set<string>();
      return result.data.map(value => {
        const model = object(value);
        if (typeof model.id !== "string" || !validModel(model.id) || ids.has(model.id)) throw new ProviderFailure("response");
        ids.add(model.id);
        const name = model.name === undefined ? model.id : optionalText(model.name);
        if (!name.trim() || name.length > 256 || /[\x00-\x1f\x7f]/.test(name)) throw new ProviderFailure("response");
        const output: ChatModel = { id: model.id, name };
        for (const [wire, field] of [["context_window", "contextWindow"], ["max_output_tokens", "maxOutputTokens"]] as const) {
          const value = model[wire];
          if (value === undefined) continue;
          if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0 || value > 1_000_000_000) throw new ProviderFailure("response");
          output[field] = value;
        }
        return output;
      });
    } catch (error) {
      signal.throwIfAborted();
      if (scope.expired()) throw new ProviderFailure("timeout");
      throw error instanceof ProviderFailure ? error : new ProviderFailure("transport");
    } finally {
      scope.close();
      if (response?.body && !response.body.locked) await response.body.cancel().catch(() => {});
    }
  }
}
