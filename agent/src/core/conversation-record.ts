import { randomUUID } from "node:crypto";
import type { Json, Message, Operation, ToolCall } from "./types.ts";

// Internal, versioned state. Not the client snapshot, and never an approval grant.
export interface ConversationRecord {
  version: 1;
  id: string;
  model: string;
  workspace: string;
  maxSteps: number;
  messages: Message[];
  operation: Operation | null;
  executingToolID: string | null;
}

export const activeStates = new Set(["running", "awaiting_approval", "cancelling"]);
export const validID = (id: string): boolean => /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(id);

function require(condition: unknown): asserts condition {
  if (!condition) throw new Error("Invalid or unsupported conversation record.");
}
function object(value: unknown): Record<string, unknown> {
  require(value !== null && typeof value === "object" && !Array.isArray(value));
  return value as Record<string, unknown>;
}
function string(value: unknown): string { require(typeof value === "string"); return value; }
function nonempty(value: unknown): string { const result = string(value); require(result.trim()); return result; }
function id(value: unknown): string { const result = string(value); require(validID(result)); return result; }
function json(value: unknown, depth = 0): Json {
  require(depth <= 64);
  if (value === null || typeof value === "string" || typeof value === "boolean") return value;
  if (typeof value === "number") { require(Number.isFinite(value)); return value; }
  if (Array.isArray(value)) return value.map(item => json(item, depth + 1));
  return Object.fromEntries(Object.entries(object(value)).map(([key, item]) => [key, json(item, depth + 1)]));
}
function call(value: unknown): ToolCall {
  const row = object(value);
  return { id: nonempty(row.id), name: nonempty(row.name), arguments: json(object(row.arguments)) as ToolCall["arguments"] };
}

// Parse defensively, including message ordering. Never cast disk JSON directly
// into executable state or silently skip malformed conversations.
export function validateRecord(value: unknown): ConversationRecord {
  const row = object(value);
  require(row.version === 1);
  const maxSteps = row.maxSteps;
  require(typeof maxSteps === "number" && Number.isSafeInteger(maxSteps) && maxSteps > 0);
  let operation: Operation | null = null;
  if (row.operation !== null) {
    const op = object(row.operation);
    const state = nonempty(op.state);
    require([...activeStates, "completed", "failed", "interrupted"].includes(state));
    operation = { id: id(op.id), state: state as Operation["state"] };
    if (op.error !== undefined) operation.error = string(op.error);
  }
  require(Array.isArray(row.messages));
  const messages: Message[] = [];
  const messageIDs = new Set<string>();
  const callIDs = new Set<string>();
  const pending: string[] = [];
  for (const [index, value] of row.messages.entries()) {
    const item = object(value);
    const messageID = id(item.id);
    require(!messageIDs.has(messageID));
    messageIDs.add(messageID);
    const text = string(item.text);
    if (item.role === "user") {
      require(pending.length === 0);
      messages.push({ id: messageID, role: "user", text });
    } else if (item.role === "assistant") {
      require(index > 0 && pending.length === 0 && Array.isArray(item.calls));
      const status = string(item.status);
      require(["streaming", "completed", "failed", "interrupted"].includes(status));
      const calls = item.calls.map(call);
      require(calls.length <= 64 && (status === "completed" || calls.length === 0));
      if (status === "streaming") require(index === row.messages.length - 1 && operation && activeStates.has(operation.state));
      for (const call of calls) {
        require(!callIDs.has(call.id));
        callIDs.add(call.id); pending.push(call.id);
      }
      messages.push({ id: messageID, role: "assistant", text, calls, status: status as Extract<Message, { role: "assistant" }>["status"] });
    } else {
      require(item.role === "tool" && pending.length > 0);
      const callID = nonempty(item.callID);
      require(pending.shift() === callID);
      const outcome = string(item.outcome);
      require(["completed", "denied", "failed", "interrupted", "not_executed"].includes(outcome));
      messages.push({ id: messageID, role: "tool", callID, text, outcome: outcome as Extract<Message, { role: "tool" }>["outcome"] });
    }
  }
  if (messages.length) require(operation && messages[0]?.role === "user");
  if (pending.length) require(operation && activeStates.has(operation.state));
  const executingToolID = row.executingToolID === null ? null : nonempty(row.executingToolID);
  if (executingToolID !== null) require(pending[0] === executingToolID && operation
    && ["running", "cancelling"].includes(operation.state));
  return { version: 1, id: id(row.id), model: nonempty(row.model), workspace: nonempty(row.workspace),
    maxSteps, messages, operation, executingToolID };
}

// Complete missing tool results conservatively. A persisted intent means execution
// may have happened, never that it succeeded or that it is safe to run again.
export function finishMissingResults(messages: Message[], executingToolID: string | null): void {
  const results = new Set(messages.filter(row => row.role === "tool").map(row => row.callID));
  const calls = messages.flatMap(row => row.role === "assistant" && row.status === "completed" ? row.calls : []);
  for (const call of calls) {
    if (results.has(call.id)) continue;
    const uncertain = call.id === executingToolID;
    messages.push({ id: randomUUID(), role: "tool", callID: call.id,
      outcome: uncertain ? "interrupted" : "not_executed",
      text: uncertain
        ? "Execution was interrupted before a durable result was recorded; it may have had effects. Do not retry without a new user request."
        : "Not executed: operation interrupted before this action started. Do not retry without a new user request." });
  }
}

export function recoverRecord(value: unknown): ConversationRecord {
  const record = validateRecord(value);
  if (!record.operation || !activeStates.has(record.operation.state)) return record;
  for (const message of record.messages) {
    if (message.role === "assistant" && message.status === "streaming") message.status = "interrupted";
  }
  finishMissingResults(record.messages, record.executingToolID);
  record.executingToolID = null;
  record.operation.state = "interrupted";
  record.operation.error = "Service restarted before the operation finished. No work was resumed.";
  return record;
}
