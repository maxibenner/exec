import { Conversation } from "../core/conversation.ts";
import type { ConversationSnapshot } from "../core/types.ts";

// One process can own many independent runners. Persistence and provider account
// ownership will be added here rather than duplicated in clients or the runtime loop.
export class AgentManager {
  private readonly conversations = new Map<string, Conversation>();

  create(options: ConstructorParameters<typeof Conversation>[0]): Conversation {
    const conversation = new Conversation(options);
    this.conversations.set(conversation.id, conversation);
    return conversation;
  }

  get(id: string): Conversation {
    const conversation = this.conversations.get(id);
    if (!conversation) throw new Error("Conversation not found.");
    return conversation;
  }

  list(): ConversationSnapshot[] {
    return [...this.conversations.values()].map(conversation => conversation.snapshot());
  }

  delete(id: string): void {
    const conversation = this.get(id);
    if (conversation.busy) throw new Error("Cannot delete an active conversation.");
    this.conversations.delete(id);
  }
}
