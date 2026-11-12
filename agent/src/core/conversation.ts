import { randomUUID } from "node:crypto";
import type {
  Approval, ChatProvider, ContextMessage, ConversationSnapshot, Message, Operation,
  OperationState, RuntimeEvent, Tool, ToolCall, ToolOutcome,
} from "./types.ts";

interface ActiveRun {
  operation: Operation;
  controller: AbortController;
}

interface PendingApproval {
  value: Approval;
  resolve(approved: boolean): void;
}

type AssistantMessage = Extract<Message, { role: "assistant" }>;

export class Conversation {
  readonly id: string;
  readonly model: string;
  readonly workspace: string;
  private readonly provider: ChatProvider;
  private readonly tools: Map<string, Tool>;
  private readonly maxSteps: number;
  private readonly messages: Message[] = [];
  private readonly listeners = new Set<(event: RuntimeEvent) => void>();
  private active: ActiveRun | undefined;
  private operation: Operation | null = null;
  private pending: PendingApproval | undefined;

  constructor(options: {
    provider: ChatProvider; model: string; workspace: string; tools?: Tool[]; maxSteps?: number;
  }) {
    if (!options.model.trim() || !options.workspace.trim()) {
      throw new Error("A model and workspace are required.");
    }
    this.id = randomUUID();
    this.model = options.model;
    this.workspace = options.workspace;
    this.provider = options.provider;
    this.maxSteps = options.maxSteps ?? 32;
    if (!Number.isSafeInteger(this.maxSteps) || this.maxSteps < 1) {
      throw new Error("maxSteps must be a positive integer.");
    }
    this.tools = new Map();
    for (const tool of options.tools ?? []) {
      const name = tool.definition.name;
      if (!name || this.tools.has(name)) throw new Error("Tool names must be nonempty and unique.");
      // Configuration is captured once. A caller cannot change a registered schema mid-run.
      this.tools.set(name, {
        definition: structuredClone(tool.definition),
        prepare: tool.prepare.bind(tool),
      });
    }
  }

  get busy(): boolean { return this.active !== undefined; }

  snapshot(): ConversationSnapshot {
    return structuredClone({
      id: this.id, model: this.model, workspace: this.workspace,
      messages: this.messages, operation: this.operation, approval: this.pending?.value ?? null,
    });
  }

  subscribe(listener: (event: RuntimeEvent) => void): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  submit(text: string): { operationID: string; completion: Promise<Operation> } {
    if (this.active) throw new Error("Conversation is busy.");
    if (!text.trim()) throw new Error("Message must not be empty.");
    const run: ActiveRun = {
      operation: { id: randomUUID(), state: "running" }, controller: new AbortController(),
    };
    this.active = run;
    this.operation = run.operation;
    this.messages.push({ id: randomUUID(), role: "user", text });
    // Run on the next microtask so the submitter has its operation ID before events arrive.
    const completion = Promise.resolve().then(() => this.run(run));
    return { operationID: run.operation.id, completion };
  }

  cancel(operationID: string): boolean {
    const run = this.active;
    if (!run || run.operation.id !== operationID
      || !["running", "awaiting_approval", "cancelling"].includes(run.operation.state)) return false;
    if (!run.controller.signal.aborted) {
      run.controller.abort();
      this.setState(run, "cancelling");
    }
    return true;
  }

  resolveApproval(operationID: string, approvalID: string, approved: boolean): boolean {
    const pending = this.pending;
    if (!pending || pending.value.id !== approvalID || pending.value.operationID !== operationID
      || this.active?.controller.signal.aborted) return false;
    pending.resolve(approved);
    return true;
  }

  private emit(event: RuntimeEvent): void {
    for (const listener of [...this.listeners]) {
      // Observers are notifications, not execution hooks. One client cannot break the run.
      try { listener(structuredClone(event)); } catch { /* Observer failure is isolated. */ }
    }
  }

  private setState(run: ActiveRun, state: OperationState): void {
    run.operation.state = state;
    this.emit({ type: "operation", conversationID: this.id, operationID: run.operation.id, state });
  }

  private changed(run: ActiveRun, message: Message): void {
    this.emit({ type: "message", conversationID: this.id, operationID: run.operation.id, messageID: message.id });
  }

  private context(): ContextMessage[] {
    const result: ContextMessage[] = [];
    for (const message of this.messages) {
      if (message.role === "user") result.push({ role: "user", text: message.text });
      else if (message.role === "assistant" && message.status === "completed") {
        result.push({ role: "assistant", text: message.text, calls: structuredClone(message.calls) });
      } else if (message.role === "tool") {
        result.push({ role: "tool", callID: message.callID, text: message.text, outcome: message.outcome });
      }
    }
    return result;
  }

  private async run(run: ActiveRun): Promise<Operation> {
    const signal = run.controller.signal;
    try {
      signal.throwIfAborted();
      this.setState(run, "running");
      for (let step = 0; step < this.maxSteps; step++) {
        signal.throwIfAborted();
        const assistant = await this.respond(run);
        // respond has finalized a complete provider response; every call must get a result,
        // even if cancellation arrived in a completion observer or between tools.
        await this.executeCalls(run, assistant.calls);
        signal.throwIfAborted();
        if (assistant.calls.length === 0) {
          this.setState(run, "completed");
          return structuredClone(run.operation);
        }
      }
      run.operation.error = "Agent step limit reached. No further request was sent.";
      this.setState(run, "failed");
    } catch {
      if (signal.aborted) this.setState(run, "interrupted");
      else {
        // Provider errors can include credentials or raw responses. Do not export them.
        run.operation.error = "Provider operation failed or returned an incomplete response. It was not retried.";
        this.setState(run, "failed");
      }
    } finally {
      this.active = undefined;
    }
    return structuredClone(run.operation);
  }

  private async respond(run: ActiveRun): Promise<AssistantMessage> {
    const signal = run.controller.signal;
    const messages = this.context();
    const message: AssistantMessage = {
      id: randomUUID(), role: "assistant", text: "", calls: [], status: "streaming",
    };
    this.messages.push(message);
    this.changed(run, message);
    const calls: ToolCall[] = [];
    const knownIDs = new Set(this.messages.flatMap(row => row.role === "assistant" ? row.calls.map(call => call.id) : []));
    let done = false;
    try {
      signal.throwIfAborted();
      for await (const event of this.provider.stream({
        model: this.model, messages,
        tools: structuredClone([...this.tools.values()].map(tool => tool.definition)), signal,
      })) {
        signal.throwIfAborted();
        if (event.type === "text") {
          message.text += event.delta;
          this.emit({ type: "text", conversationID: this.id, operationID: run.operation.id,
            messageID: message.id, delta: event.delta });
        } else if (event.type === "tool_call") {
          if (!event.call.id || !event.call.name || knownIDs.has(event.call.id) || calls.length >= 64) {
            throw new Error("Invalid tool call.");
          }
          knownIDs.add(event.call.id);
          calls.push(structuredClone(event.call));
        } else if (event.type === "done") {
          done = true;
          break;
        }
      }
      signal.throwIfAborted();
      if (!done) throw new Error("Stream ended without completion.");
      message.calls = calls;
      message.status = "completed";
      this.changed(run, message);
      return message;
    } catch (error) {
      message.status = signal.aborted ? "interrupted" : "failed";
      this.changed(run, message);
      throw error;
    }
  }

  private async executeCalls(run: ActiveRun, calls: ToolCall[]): Promise<void> {
    const signal = run.controller.signal;
    for (const call of calls) {
      let outcome: ToolOutcome = "not_executed";
      let text = "Not executed: operation interrupted. Do not retry without a new user request.";
      if (!signal.aborted) {
        const tool = this.tools.get(call.name);
        if (!tool) {
          outcome = "failed";
          text = "Unknown tool. Nothing was executed.";
        } else {
          let started = false;
          try {
            const prepared = await tool.prepare(structuredClone(call.arguments), { workspace: this.workspace, signal });
            signal.throwIfAborted();
            const approved = prepared.approval === null || await this.ask(run, call, prepared.approval);
            signal.throwIfAborted();
            if (!approved) {
              outcome = "denied";
              text = "User denied this action. Nothing was executed. Do not retry without a new user request.";
            } else {
              started = true;
              text = await prepared.execute();
              signal.throwIfAborted();
              outcome = "completed";
            }
          } catch {
            outcome = signal.aborted ? (started ? "interrupted" : "not_executed") : "failed";
            text = started
              ? "Action failed or was interrupted after execution began; it may have had effects. Do not retry without a new user request."
              : "Action did not execute. Preparation failed or the operation was interrupted. Do not retry without a new user request.";
          }
        }
      }
      const result: Message = { id: randomUUID(), role: "tool", callID: call.id, text, outcome };
      this.messages.push(result);
      this.changed(run, result);
    }
  }

  private async ask(run: ActiveRun, call: ToolCall, description: string): Promise<boolean> {
    const signal = run.controller.signal;
    signal.throwIfAborted();
    const value: Approval = {
      id: randomUUID(), operationID: run.operation.id, call: structuredClone(call), description, workspace: this.workspace,
    };
    const approved = await new Promise<boolean>(resolve => {
      const finish = (decision: boolean) => {
        if (this.pending?.value.id !== value.id) return;
        this.pending = undefined;
        signal.removeEventListener("abort", abort);
        resolve(decision);
      };
      const abort = () => finish(false);
      this.pending = { value, resolve: finish };
      signal.addEventListener("abort", abort, { once: true });
      this.setState(run, "awaiting_approval");
      if (this.pending) this.emit({ type: "approval", conversationID: this.id,
        operationID: run.operation.id, approvalID: value.id });
    });
    this.emit({ type: "approval", conversationID: this.id, operationID: run.operation.id, approvalID: null });
    signal.throwIfAborted();
    this.setState(run, "running");
    return approved;
  }
}
