import { writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { ChatProvider, Tool } from "../../src/core/types.ts";
import { AgentManager } from "../../src/manager/agent-manager.ts";
import { JsonConversationStore } from "../../src/storage/conversation-store.ts";

// A child process exits without cleanup at a real checkpoint boundary. All paths
// are supplied by a test's temporary directory; no credentials or live providers.
const [profile, phase] = process.argv.slice(2);
if (!profile || !["partial", "approval", "tool"].includes(phase ?? "")) throw new Error("Invalid fixture arguments.");
const provider: ChatProvider = {
  async *stream() {
    if (phase === "partial") {
      yield { type: "text", delta: "Saved partial response" };
      // The runtime checkpoints the first delta before requesting another one.
      process.exit(0);
    }
    yield { type: "tool_call", call: { id: "first", name: "effect", arguments: {} } };
    yield { type: "tool_call", call: { id: "second", name: "effect", arguments: {} } };
    yield { type: "done" };
  },
};
const tool: Tool = {
  definition: { name: "effect", description: "Isolated test effect", parameters: { type: "object" } },
  async prepare() {
    return { approval: phase === "approval" ? "Approve test effect" : null,
      async execute() {
        await writeFile(join(dirname(profile), "effect"), "executed once");
        process.exit(0);
      } };
  },
};
const manager = await AgentManager.open(await JsonConversationStore.open(profile), () => ({ provider, tools: [tool] }));
const conversation = await manager.create({ provider, tools: [tool], model: "fake", workspace: dirname(profile) });
conversation.subscribe(event => {
  if (phase === "approval" && event.type === "approval" && event.approvalID) process.exit(0);
});
await conversation.submit("Start test operation").completion;
throw new Error("Fixture did not exit at its intended boundary.");
