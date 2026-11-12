export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

export interface ToolCall {
  id: string;
  name: string;
  arguments: { [key: string]: Json };
}

export interface ToolDefinition {
  name: string;
  description: string;
  parameters: { [key: string]: Json };
}

export type ToolOutcome = "completed" | "denied" | "failed" | "interrupted" | "not_executed";
export type Message =
  | { id: string; role: "user"; text: string }
  | { id: string; role: "assistant"; text: string; calls: ToolCall[];
      status: "streaming" | "completed" | "failed" | "interrupted" }
  | { id: string; role: "tool"; callID: string; text: string; outcome: ToolOutcome };

// Only finalized assistant messages and paired tool results enter provider context.
export type ContextMessage =
  | { role: "user"; text: string }
  | { role: "assistant"; text: string; calls: ToolCall[] }
  | { role: "tool"; callID: string; text: string; outcome: ToolOutcome };

export interface ProviderRequest {
  model: string;
  messages: ContextMessage[];
  tools: ToolDefinition[];
  signal: AbortSignal;
}

export type ProviderEvent =
  | { type: "text"; delta: string }
  | { type: "tool_call"; call: ToolCall }
  | { type: "done" };

export interface ChatModel {
  id: string;
  name: string;
  contextWindow?: number;
  maxOutputTokens?: number;
}

export interface ChatProvider {
  // Adapters decode their own wire format and yield fully parsed tool calls.
  // They must honor cancellation and must not retry inference automatically.
  stream(request: ProviderRequest): AsyncIterable<ProviderEvent>;
  models?(signal: AbortSignal): Promise<ChatModel[]>;
}

export interface ToolContext {
  workspace: string;
  signal: AbortSignal;
}

export interface PreparedTool {
  // Null is an explicit declaration that this action does not need approval.
  approval: string | null;
  // Capture the exact prepared action; edits must revalidate before writing.
  execute(): Promise<string>;
}

export interface Tool {
  definition: ToolDefinition;
  // Validate/prepare only: no side effects before the runtime grants approval.
  prepare(arguments_: ToolCall["arguments"], context: ToolContext): Promise<PreparedTool>;
}

export type OperationState = "running" | "awaiting_approval" | "cancelling"
  | "completed" | "failed" | "interrupted";

export interface Operation {
  id: string;
  state: OperationState;
  error?: string;
}

export interface Approval {
  id: string;
  operationID: string;
  call: ToolCall;
  description: string;
  workspace: string;
}

export interface ConversationSnapshot {
  id: string;
  model: string;
  workspace: string;
  messages: Message[];
  operation: Operation | null;
  approval: Approval | null;
  storageError: string | null;
}

export type RuntimeEvent = {
  conversationID: string;
  operationID: string;
} & (
  | { type: "operation"; state: OperationState }
  | { type: "message"; messageID: string }
  | { type: "text"; messageID: string; delta: string }
  | { type: "approval"; approvalID: string | null }
);
