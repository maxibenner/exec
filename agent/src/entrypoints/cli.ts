import { homedir } from "node:os";
import { resolve } from "node:path";
import { createInterface } from "node:readline/promises";
import { AgentClient } from "../client/agent-client.ts";
import { followConversation, terminalText, Transcript } from "../client/terminal.ts";
import { activeOperation, type SubmitTurnResponse } from "../service/protocol.ts";
import { serve } from "./serve.ts";

const help = `Exec agent CLI (local service client)

Usage: npm run cli -- [--profile PATH] COMMAND
  serve [--credentials PATH] [--workspace-tools]
                                      Run the service in the foreground (DeepSeek)
  health                              Show service capabilities
  models                              Discover provider models
  list                                List saved conversations
  new MODEL [WORKSPACE]               Create a conversation (workspace defaults to cwd)
  show ID                             Show saved/current conversation state
  chat ID                             Interactive chat; requires a terminal
  send ID MESSAGE                     Submit one message and follow its operation
  watch ID                            Observe until Ctrl-C; never approves automatically
  cancel ID OPERATION_ID              Cancel exactly that operation
  approve ID OPERATION_ID APPROVAL_ID  Approve exactly that pending action
  deny ID OPERATION_ID APPROVAL_ID     Deny exactly that pending action

Default profile: ~/.exec-agent
Only serve starts a service. There are no automatic request retries.
serve reads DEEPSEEK_API_KEY, otherwise PROFILE/credentials.json (private mode 0600).
--credentials selects another JSON file; environment credentials take precedence.
Restart serve after changing credentials. Keys are never accepted as arguments.
In chat, /quit or EOF detaches; Ctrl-C cancels an active turn or exits while idle.
In send, pending approvals must be resolved explicitly from another client.
`;

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  let profile = resolve(homedir(), ".exec-agent");
  if (args[0] === "--profile") {
    args.shift();
    const value = args.shift();
    if (!value || value.startsWith("--")) throw new Error("--profile requires a path.");
    profile = resolve(value);
  }
  const command = args.shift();
  if (!command || command === "--help" || command === "help") { process.stdout.write(help); return; }
  if (command === "serve") {
    let credentialsPath: string | undefined;
    let workspaceTools = false;
    while (args.length) {
      const flag = args.shift();
      if (flag === "--workspace-tools" && !workspaceTools) workspaceTools = true;
      else if (flag === "--credentials" && credentialsPath === undefined) {
        const value = args.shift();
        if (!value || value.startsWith("--")) throw new Error("--credentials requires a path.");
        credentialsPath = resolve(value);
      } else throw new Error("Invalid serve arguments. Use --help.");
    }
    await serve({ profile, ...(credentialsPath === undefined ? {} : { credentialsPath }), workspaceTools });
    return;
  }
  const arity: Record<string, [number, number]> = {
    health: [0, 0], models: [0, 0], list: [0, 0], new: [1, 2], show: [1, 1],
    chat: [1, 1], send: [2, 2], watch: [1, 1], cancel: [2, 2], approve: [3, 3], deny: [3, 3],
  };
  const count = arity[command];
  if (!count || args.length < count[0] || args.length > count[1]) throw new Error("Invalid command arguments. Use --help.");
  const client = new AgentClient(resolve(profile, "service.sock"));
  const print = (value: unknown) => process.stdout.write(terminalText(JSON.stringify(value, null, 2)) + "\n");
  const [id, argument, approvalID] = args as [string, string, string];
  switch (command) {
    case "health": print(await client.health()); return;
    case "models": print(await client.models()); return;
    case "list": print(await client.list()); return;
    case "new": print(await client.create(id, resolve(argument ?? process.cwd()))); return;
    case "show": print(await client.get(id)); return;
    case "cancel": print(await client.cancel(id, argument)); return;
    case "approve": case "deny": print(await client.approve(id, argument, approvalID, command === "approve")); return;
  }
  if (command === "chat" && (!process.stdin.isTTY || !process.stdout.isTTY)) {
    throw new Error("chat requires an interactive terminal. Use send/watch and explicit approve/deny commands for scripts.");
  }
  const lifetime = new AbortController();
  const transcript = new Transcript(text => process.stdout.write(text));
  const readline = command === "chat" ? createInterface({ input: process.stdin, output: process.stdout }) : undefined;
  let question: AbortController | undefined;
  let signalling = false;
  let submitting: Promise<SubmitTurnResponse> | undefined;
  const ask = async (prompt: string): Promise<string | undefined> => {
    question = new AbortController();
    try { return await readline!.question(prompt, { signal: AbortSignal.any([question.signal, lifetime.signal]) }); }
    catch { return undefined; }
    finally { question = undefined; }
  };
  const interrupt = () => {
    if (signalling) return;
    if (command === "watch") { lifetime.abort(); return; }
    signalling = true;
    void (async () => {
      // Wait for our own submit acknowledgment before resolving cancellation.
      // A lost acknowledgment is never retried; inspect the state instead.
      if (submitting) await submitting;
      const snapshot = await client.get(id);
      if (activeOperation(snapshot)) {
        await client.cancel(id, snapshot.operation!.id);
        question?.abort();
      } else { lifetime.abort(); readline?.close(); }
    })().catch(() => {
      process.stderr.write("Cancellation could not be confirmed. Inspect the conversation before continuing.\n");
      lifetime.abort(); readline?.close();
    }).finally(() => { signalling = false; });
  };
  const onClose = () => { lifetime.abort(); question?.abort(); };
  process.on("SIGINT", interrupt);
  readline?.on("SIGINT", interrupt);
  readline?.on("close", onClose);
  try {
    if (command === "watch") {
      await followConversation(client, id, transcript, { signal: lifetime.signal, continuous: true });
      return;
    }
    if (command === "send") {
      submitting = client.submit(id, argument);
      const { operationID } = await submitting;
      submitting = undefined;
      const operation = await followConversation(client, id, transcript, { signal: lifetime.signal, operationID });
      if (operation?.state !== "completed") process.exitCode = 1;
      return;
    }
    const approve = async () => {
      const answer = await ask("\nApprove this exact action? [y/N] ");
      return answer === undefined ? undefined : answer.trim().toLowerCase() === "y";
    };
    await followConversation(client, id, transcript, { signal: lifetime.signal, approve });
    while (!lifetime.signal.aborted) {
      const input = await ask("\nYou> ");
      if (input === undefined || input.trim() === "/quit") break;
      if (!input.trim()) continue;
      submitting = client.submit(id, input);
      const { operationID } = await submitting;
      submitting = undefined;
      await followConversation(client, id, transcript, { signal: lifetime.signal, operationID, approve });
    }
  } finally {
    lifetime.abort(); question?.abort();
    process.off("SIGINT", interrupt);
    readline?.off("SIGINT", interrupt);
    readline?.off("close", onClose);
    readline?.close();
  }
}

void main().catch(error => {
  process.stderr.write(terminalText(error instanceof Error ? error.message : "CLI failed.") + "\n");
  process.exitCode = 1;
});
