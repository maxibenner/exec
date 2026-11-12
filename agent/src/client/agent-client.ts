import { request, type IncomingMessage } from "node:http";
import { APIError, type ConversationSummary, type ServiceEvent } from "../service/protocol.ts";
import type { ChatModel, ConversationSnapshot } from "../core/types.ts";

const maxResponse = 32 * 1024 * 1024;
const base = "/v1/conversations";
function path(id: string): string { return `${base}/${encodeURIComponent(id)}`; }

// No retries, redirects, cookies, or implicit inference. A failed mutation may
// already have taken effect: inspect the latest snapshot rather than replay it.
export class AgentClient {
  readonly socketPath: string;
  constructor(socketPath: string) { this.socketPath = socketPath; }

  private async open(method: string, route: string, value?: unknown, signal?: AbortSignal): Promise<IncomingMessage> {
    const data = value === undefined ? undefined : JSON.stringify(value);
    return new Promise((resolve, reject) => {
      const req = request({ socketPath: this.socketPath, path: route, method, signal, agent: false,
        headers: data === undefined ? {} : { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(data) },
      }, resolve);
      req.on("error", () => reject(new APIError(0,
        "Service connection failed. The request may have taken effect; inspect the conversation before continuing.")));
      req.end(data);
    });
  }

  private async read(response: IncomingMessage): Promise<unknown> {
    const chunks: Buffer[] = [];
    let size = 0;
    try {
      for await (const chunk of response) {
        size += chunk.length;
        if (size > maxResponse) throw new Error();
        chunks.push(chunk);
      }
      const value: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks)));
      if ((response.statusCode ?? 500) >= 400) {
        // Don't render arbitrary error bodies from a misconfigured endpoint.
        throw new APIError(response.statusCode!, `Service rejected request (HTTP ${response.statusCode}). Inspect conversation state before continuing.`);
      }
      return value;
    } catch (error) {
      if (error instanceof APIError) throw error;
      throw new APIError(0, "Invalid or interrupted service response. Do not automatically repeat the request.");
    } finally { response.destroy(); }
  }

  async call<T>(method: string, route: string, value?: unknown, signal?: AbortSignal): Promise<T> {
    const deadline = AbortSignal.timeout(130_000);
    const combined = signal ? AbortSignal.any([signal, deadline]) : deadline;
    return await this.read(await this.open(method, route, value, combined)) as T;
  }
  health(): Promise<{ version: number; toolsEnabled: boolean }> { return this.call("GET", "/v1/health"); }
  models(): Promise<ChatModel[]> { return this.call("GET", "/v1/models"); }
  list(): Promise<ConversationSummary[]> { return this.call("GET", base); }
  create(model: string, workspace: string): Promise<ConversationSnapshot> { return this.call("POST", base, { model, workspace }); }
  get(id: string): Promise<ConversationSnapshot> { return this.call("GET", path(id)); }
  submit(id: string, text: string): Promise<{ operationID: string }> { return this.call("POST", `${path(id)}/turns`, { text }); }
  cancel(id: string, operationID: string): Promise<{ cancelled: boolean }> { return this.call("POST", `${path(id)}/cancel`, { operationID }); }
  approve(id: string, operationID: string, approvalID: string, approved: boolean): Promise<{ resolved: boolean }> {
    return this.call("POST", `${path(id)}/approvals`, { operationID, approvalID, approved });
  }

  async *events(id: string, signal?: AbortSignal): AsyncGenerator<ServiceEvent> {
    const controller = new AbortController();
    const combined = signal ? AbortSignal.any([signal, controller.signal]) : controller.signal;
    // Opening is bounded; an established event stream may remain idle indefinitely.
    const timer = setTimeout(() => controller.abort(), 15_000);
    let response: IncomingMessage | undefined;
    try {
      response = await this.open("GET", `${path(id)}/events`, undefined, combined);
      clearTimeout(timer);
      if (response.statusCode !== 200) { await this.read(response); throw new Error(); }
      if (response.headers["content-type"] !== "application/x-ndjson") throw new Error();
      const decoder = new TextDecoder("utf-8", { fatal: true });
      let pending = "";
      for await (const chunk of response) {
        pending += decoder.decode(chunk, { stream: true });
        if (Buffer.byteLength(pending) > maxResponse) throw new Error();
        let newline: number;
        while ((newline = pending.indexOf("\n")) !== -1) {
          const value = JSON.parse(pending.slice(0, newline)) as ServiceEvent;
          pending = pending.slice(newline + 1);
          if (!value || (value.type !== "snapshot" && value.type !== "runtime")) throw new Error();
          yield value;
        }
      }
      decoder.decode();
      throw new Error(); // An event feed does not have a normal terminal EOF.
    } catch (error) {
      if (signal?.aborted) return;
      if (error instanceof APIError) throw error;
      throw new APIError(0, "Event stream interrupted. Reconnect explicitly to obtain the latest snapshot; do not resubmit work.");
    } finally { clearTimeout(timer); controller.abort(); response?.destroy(); }
  }
}
