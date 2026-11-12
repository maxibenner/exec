import { Conversation, type ConversationOptions } from "../core/conversation.ts";
import { activeStates, type ConversationRecord } from "../core/conversation-record.ts";
import type { ConversationSnapshot } from "../core/types.ts";
import type { ConversationStore } from "../storage/conversation-store.ts";

type CreateOptions = Omit<ConversationOptions, "checkpoint">;
type Configuration = Pick<ConversationRecord, "id" | "model" | "workspace" | "maxSteps">;
type RuntimeDependencies = Pick<ConversationOptions, "provider" | "tools">;

// The in-memory constructor remains useful for tests/embedding. open() transfers
// ownership of a durable store and restores every record before publishing it.
export class AgentManager {
  private readonly conversations = new Map<string, Conversation>();
  private readonly mutating = new Set<string>();
  private store: ConversationStore | undefined;
  private closed = false;

  static async open(store: ConversationStore, configure: (saved: Configuration) => RuntimeDependencies): Promise<AgentManager> {
    const manager = new AgentManager();
    manager.store = store;
    try {
      for (const record of await store.load()) {
        const { id, model, workspace, maxSteps } = record;
        const dependencies = configure({ id, model, workspace, maxSteps });
        const conversation = new Conversation({ ...dependencies, model, workspace, maxSteps,
          checkpoint: value => store.save(value) }, record);
        if (record.operation && activeStates.has(record.operation.state)) await store.save(conversation.record());
        manager.conversations.set(id, conversation);
      }
      return manager;
    } catch {
      for (const conversation of manager.conversations.values()) conversation.dispose();
      await store.close().catch(() => {}); // Release ownership, never replay work or rewrite corrupt data.
      throw new Error("Could not restore conversations. No work was resumed; inspect the profile before continuing.");
    }
  }

  private assertOpen(): void {
    if (this.closed) throw new Error("Agent manager is closed.");
  }

  async create(options: CreateOptions): Promise<Conversation> {
    this.assertOpen();
    const conversation = new Conversation({ ...options,
      ...(this.store ? { checkpoint: (record: ConversationRecord) => this.store!.save(record) } : {}) });
    this.mutating.add(conversation.id);
    try {
      if (this.store) await this.store.save(conversation.record());
      this.conversations.set(conversation.id, conversation);
      return conversation;
    } catch (error) {
      conversation.dispose();
      throw error;
    } finally { this.mutating.delete(conversation.id); }
  }

  get(id: string): Conversation {
    this.assertOpen();
    if (this.mutating.has(id)) throw new Error("Conversation catalog operation is pending.");
    const conversation = this.conversations.get(id);
    if (!conversation) throw new Error("Conversation not found.");
    return conversation;
  }

  list(): ConversationSnapshot[] {
    this.assertOpen();
    return [...this.conversations.values()].map(conversation => conversation.snapshot());
  }

  async delete(id: string): Promise<void> {
    const conversation = this.get(id);
    if (conversation.busy) throw new Error("Cannot delete an active conversation.");
    // References held by clients must not resurrect a deleted conversation.
    conversation.dispose();
    this.mutating.add(id);
    try {
      if (this.store) await this.store.delete(id);
      this.conversations.delete(id);
    } finally { this.mutating.delete(id); }
  }

  async close(): Promise<void> {
    this.assertOpen();
    if (this.mutating.size || [...this.conversations.values()].some(conversation => conversation.busy)) {
      throw new Error("Stop and await active conversations/catalog operations before closing the manager.");
    }
    this.closed = true;
    for (const conversation of this.conversations.values()) conversation.dispose();
    if (this.store) await this.store.close();
  }
}
