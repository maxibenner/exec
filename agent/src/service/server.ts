import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { lstat, mkdir, realpath, stat, chmod } from "node:fs/promises";
import { dirname, isAbsolute, join } from "node:path";
import type { Socket } from "node:net";
import type { ChatProvider, Tool } from "../core/types.ts";
import { AgentManager } from "../manager/agent-manager.ts";
import {
  APIError, parseIdentifier, parseCreateConversationRequest, parseSubmitTurnRequest,
  parseCancelOperationRequest, parseResolveApprovalRequest,
  type ServiceEvent, type HealthResponse, type ModelsResponse, type ListConversationsResponse,
  type CreateConversationResponse, type GetConversationResponse, type SubmitTurnResponse,
  type CancelOperationResponse, type ResolveApprovalResponse, type ErrorResponse,
} from "./protocol.ts";

const maxBody = 256 * 1024;

// Never relax permissions on an existing directory, follow a final symlink, or
// unlink an existing socket. A stale socket requires an explicit operator decision.
export async function privateDirectory(path: string): Promise<string> {
  if (!isAbsolute(path)) throw new Error("An absolute profile path is required.");
  await mkdir(path, { recursive: true, mode: 0o700 });
  const info = await lstat(path);
  if (!info.isDirectory() || info.uid !== process.getuid?.() || (info.mode & 0o077) !== 0) {
    throw new Error("Profile must be an owned, private directory (mode 0700).");
  }
  return realpath(path);
}

async function body(request: IncomingMessage): Promise<unknown> {
  if (request.headers["content-type"] !== "application/json") throw new APIError(415, "Use application/json.");
  let size = 0;
  const chunks: Buffer[] = [];
  for await (const chunk of request) {
    size += chunk.length;
    if (size > maxBody) throw new APIError(413, "Request is too large.");
    chunks.push(chunk);
  }
  try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks))); }
  catch { throw new APIError(400, "Invalid JSON."); }
}
function json<T>(response: ServerResponse, status: number, value: T): void {
  response.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
  response.end(JSON.stringify(value));
}

export interface ServiceOptions {
  manager: AgentManager;
  provider: ChatProvider;
  tools?: Tool[];
  socketPath: string;
}

// The service owns the manager after listen succeeds. Disconnecting a client
// never cancels work; only explicit cancellation or service shutdown does.
export async function startService(options: ServiceOptions): Promise<{ close(): Promise<void> }> {
  const { manager, provider, socketPath } = options;
  if (!isAbsolute(socketPath) || Buffer.byteLength(socketPath) > 100) throw new Error("Socket path must be absolute and at most 100 bytes.");
  await privateDirectory(dirname(socketPath));
  const sockets = new Set<Socket>();
  const handlers = new Set<Promise<void>>();
  const runs = new Map<string, { cancel(): void; completion: Promise<unknown> }>();
  let stopping = false;
  let closing: Promise<void> | undefined;

  async function handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
    if (request.headers.origin || request.headers["sec-fetch-site"]) throw new APIError(403, "Browser requests are not supported.");
    if (stopping) throw new APIError(503, "Service is stopping.");
    const route = request.url ?? "";
    const method = request.method;
    if (method === "GET" && route === "/v1/health") return json<HealthResponse>(response, 200, { version: 1, toolsEnabled: !!options.tools?.length });
    if (method === "GET" && route === "/v1/models") {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 120_000);
      const abort = () => controller.abort();
      response.on("close", abort);
      try { json<ModelsResponse>(response, 200, await provider.models?.(controller.signal) ?? []); }
      finally { clearTimeout(timer); response.off("close", abort); }
      return;
    }
    if (route === "/v1/conversations") {
      if (method === "GET") {
        return json<ListConversationsResponse>(response, 200, manager.list().map(({ messages: _messages, approval: _approval, ...summary }) => summary));
      }
      if (method === "POST") {
        const { model, workspace } = parseCreateConversationRequest(await body(request));
        if (!isAbsolute(workspace)) throw new APIError(400, "Workspace must be absolute.");
        let canonical: string;
        try { canonical = await realpath(workspace); if (!(await stat(canonical)).isDirectory()) throw new Error(); }
        catch { throw new APIError(400, "Workspace must be an existing directory."); }
        if (stopping) throw new APIError(503, "Service is stopping.");
        const conversation = await manager.create({ model, workspace: canonical, provider, tools: options.tools ?? [] });
        return json<CreateConversationResponse>(response, 201, conversation.snapshot());
      }
    }
    const match = /^\/v1\/conversations\/([^/]+)(?:\/(events|turns|cancel|approvals))?$/.exec(route);
    if (!match) throw new APIError(404, "Route not found.");
    const conversationID = parseIdentifier(match[1]);
    let conversation;
    try { conversation = manager.get(conversationID); }
    catch { throw new APIError(404, "Conversation not found."); }
    const action = match[2];
    if (!action && method === "GET") return json<GetConversationResponse>(response, 200, conversation.snapshot());
    if (action === "events" && method === "GET") {
      response.writeHead(200, { "Content-Type": "application/x-ndjson", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" });
      const send = (event: ServiceEvent) => {
        // A stalled observer must not accumulate an unbounded queue or block work.
        if (response.destroyed) return;
        if (response.writableLength > 1024 * 1024) { response.destroy(); return; }
        response.write(JSON.stringify(event) + "\n");
      };
      const unsubscribe = conversation.subscribe(event => send(event.type === "text"
        ? { type: "runtime", event }
        : { type: "runtime", event, snapshot: conversation.snapshot() }));
      response.once("close", unsubscribe);
      // Synchronous subscription + snapshot: no event gap and no replay log.
      send({ type: "snapshot", snapshot: conversation.snapshot() });
      return;
    }
    if (action === "turns" && method === "POST") {
      const { text: input } = parseSubmitTurnRequest(await body(request));
      if (stopping) throw new APIError(503, "Service is stopping.");
      if (conversation.busy || conversation.snapshot().storageError) throw new APIError(409, "Conversation is busy or requires recovery.");
      let run;
      try { run = conversation.submit(input); }
      catch { throw new APIError(409, "Conversation cannot accept work."); }
      runs.set(run.operationID, { cancel: () => { conversation.cancel(run.operationID); }, completion: run.completion });
      void run.completion.then(() => runs.delete(run.operationID), () => runs.delete(run.operationID));
      // Acceptance is in-memory, not a durable receipt. Never replay a lost POST.
      return json<SubmitTurnResponse>(response, 202, { operationID: run.operationID });
    }
    if (action === "cancel" && method === "POST") {
      const { operationID } = parseCancelOperationRequest(await body(request));
      if (!conversation.cancel(operationID)) throw new APIError(409, "Operation is no longer cancellable.");
      return json<CancelOperationResponse>(response, 202, { accepted: true, operationID });
    }
    if (action === "approvals" && method === "POST") {
      const { operationID, approvalID, approved } = parseResolveApprovalRequest(await body(request));
      if (!conversation.resolveApproval(operationID, approvalID, approved)) {
        throw new APIError(409, "Approval is stale or already resolved.");
      }
      return json<ResolveApprovalResponse>(response, 200, { resolved: true });
    }
    throw new APIError(405, "Method not allowed.");
  }

  const server = createServer({ requestTimeout: 15_000, headersTimeout: 10_000, maxHeaderSize: 8192 }, (request, response) => {
    const task = handle(request, response).catch(error => {
      if (response.headersSent || response.destroyed) { response.destroy(); return; }
      json<ErrorResponse>(response, error instanceof APIError ? error.status : 500,
        { error: error instanceof APIError ? error.message : "Service request failed. Inspect conversation state before continuing." });
    });
    handlers.add(task);
    void task.finally(() => handlers.delete(task));
  });
  server.maxConnections = 64;
  server.on("connection", socket => { sockets.add(socket); socket.once("close", () => sockets.delete(socket)); });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, () => { server.off("error", reject); resolve(); });
  });
  try { await chmod(socketPath, 0o600); }
  catch (error) { await new Promise<void>(resolve => server.close(() => resolve())); throw error; }
  return {
    close() {
      closing ??= (async () => {
        stopping = true;
        const closed = new Promise<void>(resolve => server.close(() => resolve()));
        for (const socket of sockets) socket.destroy();
        await Promise.allSettled([...handlers]);
        for (const run of runs.values()) run.cancel();
        await Promise.allSettled([...runs.values()].map(run => run.completion));
        await closed;
        await manager.close();
      })();
      return closing;
    },
  };
}

export const profileSocket = (profile: string): string => join(profile, "service.sock");
