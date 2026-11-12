import { join } from "node:path";
import type { ChatProvider } from "../core/types.ts";
import { AgentManager } from "../manager/agent-manager.ts";
import { JsonConversationStore } from "../storage/conversation-store.ts";
import { createWorkspaceTools } from "../tools/index.ts";
import { privateDirectory, profileSocket, startService } from "./server.ts";

export interface PersistentServiceOptions {
  profile: string;
  provider: ChatProvider;
  workspaceTools?: boolean;
}

// Composition root shared by the eventual executable and embedded hosts.
// Credentials stay with the caller/provider; they never cross the client API.
export async function startPersistentService(options: PersistentServiceOptions): Promise<{ close(): Promise<void> }> {
  const profile = await privateDirectory(options.profile);
  const tools = options.workspaceTools ? createWorkspaceTools() : [];
  const store = await JsonConversationStore.open(join(profile, "conversations"));
  const manager = await AgentManager.open(store, () => ({ provider: options.provider, tools }));
  try {
    return await startService({ manager, provider: options.provider, tools, socketPath: profileSocket(profile) });
  } catch (error) {
    await manager.close();
    throw error;
  }
}
