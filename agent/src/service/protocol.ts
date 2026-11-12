import type { ChatModel, ConversationSnapshot, RuntimeEvent } from "../core/types.ts";

// Transport-neutral v1 contracts shared by the server and clients. Wire parsing
// for commands lives here too; filesystem/provider checks stay in the service.
export interface CreateConversationRequest { model: string; workspace: string }
export interface SubmitTurnRequest { text: string }
export interface CancelOperationRequest { operationID: string }
export interface ResolveApprovalRequest { operationID: string; approvalID: string; approved: boolean }

export interface HealthResponse { version: 1; toolsEnabled: boolean }
export type ModelsResponse = ChatModel[];
export type ConversationSummary = Omit<ConversationSnapshot, "messages" | "approval">;
export type ListConversationsResponse = ConversationSummary[];
export type CreateConversationResponse = ConversationSnapshot;
export type GetConversationResponse = ConversationSnapshot;
export interface SubmitTurnResponse { operationID: string }
export interface CancelOperationResponse { accepted: true; operationID: string }
export interface ResolveApprovalResponse { resolved: true }
export interface ErrorResponse { error: string }

export type ServiceEvent =
  | { type: "snapshot"; snapshot: ConversationSnapshot }
  | { type: "runtime"; event: Extract<RuntimeEvent, { type: "text" }>; snapshot?: never }
  | { type: "runtime"; event: Exclude<RuntimeEvent, { type: "text" }>; snapshot: ConversationSnapshot };

export const activeOperation = (snapshot: ConversationSnapshot): boolean =>
  !!snapshot.operation && ["running", "awaiting_approval", "cancelling"].includes(snapshot.operation.state);

export class APIError extends Error {
  readonly status: number;
  constructor(status: number, message: string) { super(message); this.status = status; }
}

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function parseIdentifier(value: unknown): string {
  if (typeof value !== "string" || !uuid.test(value)) throw new APIError(400, "Invalid identifier.");
  return value;
}
function text(value: unknown, max: number): string {
  if (typeof value !== "string" || !value.trim() || value.length > max || value.includes("\0")) {
    throw new APIError(400, "Invalid string field.");
  }
  return value;
}
function boolean(value: unknown): boolean {
  if (typeof value !== "boolean") throw new APIError(400, "Expected a boolean field.");
  return value;
}

// Every required request field must have a decoder. Adding/changing a contract
// therefore also checks the validator at compile time; unknown keys fail closed.
function object<T extends object>(value: unknown, fields: { [K in keyof T]-?: (value: unknown) => T[K] }): T {
  if (!value || typeof value !== "object" || Array.isArray(value)
    || Object.keys(value).some(key => !Object.hasOwn(fields, key))) throw new APIError(400, "Invalid request fields.");
  const input = value as Record<string, unknown>;
  const result = {} as T;
  for (const key of Object.keys(fields) as (keyof T & string)[]) {
    result[key] = fields[key](Object.hasOwn(input, key) ? input[key] : undefined);
  }
  return result;
}

export const parseCreateConversationRequest = (value: unknown): CreateConversationRequest =>
  object<CreateConversationRequest>(value, { model: value => text(value, 128), workspace: value => text(value, 4096) });
export const parseSubmitTurnRequest = (value: unknown): SubmitTurnRequest =>
  object<SubmitTurnRequest>(value, { text: value => text(value, 128 * 1024) });
export const parseCancelOperationRequest = (value: unknown): CancelOperationRequest =>
  object<CancelOperationRequest>(value, { operationID: parseIdentifier });
export const parseResolveApprovalRequest = (value: unknown): ResolveApprovalRequest =>
  object<ResolveApprovalRequest>(value, { operationID: parseIdentifier, approvalID: parseIdentifier, approved: boolean });
