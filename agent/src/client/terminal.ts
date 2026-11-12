import type { Approval, ConversationSnapshot, Operation } from "../core/types.ts";
import { activeOperation } from "../service/protocol.ts";
import { AgentClient } from "./agent-client.ts";

// Model/tool output must never become terminal escape sequences (including OSC
// clipboard/title commands), bidi overrides, or invisible control characters.
export function terminalText(text: string): string {
  return text.replace(/[\x00-\x08\x0b-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]/g,
    character => `\\u{${character.codePointAt(0)!.toString(16)}}`);
}

export class Transcript {
  private readonly lengths = new Map<string, number>();
  private readonly approvals = new Set<string>();
  private readonly terminalOperations = new Set<string>();
  private readonly write: (text: string) => void;
  constructor(write: (text: string) => void) { this.write = write; }

  snapshot(snapshot: ConversationSnapshot): void {
    for (const message of snapshot.messages) {
      if (!this.lengths.has(message.id)) {
        this.write(`\n[${message.role}${message.role === "tool" ? `: ${message.outcome}` : ""}]\n`);
        this.lengths.set(message.id, 0);
      }
      const previous = this.lengths.get(message.id)!;
      this.write(terminalText(message.text.slice(previous)));
      this.lengths.set(message.id, message.text.length);
    }
    const approval = snapshot.approval;
    if (approval && !this.approvals.has(approval.id)) {
      this.approvals.add(approval.id);
      this.write(`\n\n[Approval ${approval.id}]\nOperation: ${approval.operationID}\nWorkspace: ${terminalText(approval.workspace)}\n${terminalText(approval.description)}\n`);
    }
    if (snapshot.operation && !activeOperation(snapshot) && !this.terminalOperations.has(snapshot.operation.id)) {
      this.terminalOperations.add(snapshot.operation.id);
      this.write(`\n[${snapshot.operation.state}]${snapshot.operation.error ? ` ${terminalText(snapshot.operation.error)}` : ""}\n`);
    }
    if (snapshot.storageError) this.write(`\n${terminalText(snapshot.storageError)}\n`);
  }

  delta(messageID: string, delta: string): void {
    if (!this.lengths.has(messageID)) { this.write("\n[assistant]\n"); this.lengths.set(messageID, 0); }
    this.write(terminalText(delta));
    this.lengths.set(messageID, this.lengths.get(messageID)! + delta.length);
  }
}

export async function followConversation(client: AgentClient, id: string, transcript: Transcript, options: {
  signal?: AbortSignal;
  operationID?: string;
  continuous?: boolean;
  approve?: (approval: Approval) => Promise<boolean | undefined>;
} = {}): Promise<Operation | null> {
  const prompted = new Set<string>();
  for await (const frame of client.events(id, options.signal)) {
    if (frame.type === "runtime" && frame.event.type === "text") {
      transcript.delta(frame.event.messageID, frame.event.delta);
    }
    const snapshot = frame.snapshot;
    if (!snapshot) continue;
    transcript.snapshot(snapshot);
    if (options.operationID && snapshot.operation?.id !== options.operationID) {
      throw new Error("Another client changed the active operation. Inspect the conversation before continuing.");
    }
    if (!options.continuous && !activeOperation(snapshot)) return snapshot.operation;
    if (snapshot.approval && options.approve && !prompted.has(snapshot.approval.id)) {
      const approval = snapshot.approval;
      prompted.add(approval.id);
      const approved = await options.approve(approval);
      if (approved !== undefined) await client.approve(id, approval.operationID, approval.id, approved);
    }
  }
  return null;
}
