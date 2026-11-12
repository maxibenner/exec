import type { ConversationSnapshot, RuntimeEvent } from "../core/types.ts";

export type ServiceEvent =
  | { type: "snapshot"; snapshot: ConversationSnapshot }
  | { type: "runtime"; event: RuntimeEvent; snapshot?: ConversationSnapshot };

export type ConversationSummary = Omit<ConversationSnapshot, "messages" | "approval">;
export const activeOperation = (snapshot: ConversationSnapshot): boolean =>
  !!snapshot.operation && ["running", "awaiting_approval", "cancelling"].includes(snapshot.operation.state);

export class APIError extends Error {
  readonly status: number;
  constructor(status: number, message: string) { super(message); this.status = status; }
}
