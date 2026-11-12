import { spawn } from "node:child_process";
import { homedir, tmpdir } from "node:os";
import type { Tool } from "../core/types.ts";
import { ToolFailure } from "../core/tool-failure.ts";
import { fields, integer, schema, string } from "./arguments.ts";
import { Workspace } from "./workspace.ts";

class OutputCapture {
  private first = Buffer.alloc(0);
  private last = Buffer.alloc(0);
  private size = 0;
  private readonly half = 15000;

  append(chunk: Buffer): void {
    this.size += chunk.length;
    if (this.first.length < this.half) {
      this.first = Buffer.concat([this.first, chunk.subarray(0, this.half - this.first.length)]);
    }
    this.last = Buffer.concat([this.last, chunk]).subarray(-this.half);
  }

  text(): string {
    if (this.size <= this.half * 2) {
      const remainder = this.size - this.first.length;
      return Buffer.concat([this.first, remainder > 0 ? this.last.subarray(-remainder) : Buffer.alloc(0)]).toString("utf8");
    }
    return this.first.toString("utf8")
      + `\n[Output truncated: captured first/last 15,000 bytes of ${this.size} bytes. Full output was not retained.]\n`
      + this.last.toString("utf8");
  }
}

// Deliberately do not inherit process.env: no provider keys, service tokens,
// BASH_ENV, loader injection variables, or other ambient application secrets.
function shellEnvironment(): NodeJS.ProcessEnv {
  return {
    PATH: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    HOME: homedir(), TMPDIR: tmpdir(), LANG: "C",
  };
}

async function run(command: string, cwd: string, timeoutSeconds: number, signal: AbortSignal): Promise<string> {
  signal.throwIfAborted();
  return new Promise<string>((resolve, reject) => {
    const output = new OutputCapture();
    const child = spawn("/bin/bash", ["--noprofile", "--norc", "-c", command], {
      cwd, env: shellEnvironment(), detached: true, stdio: ["ignore", "pipe", "pipe"],
    });
    let reason: "cancelled" | "timeout" | "spawn_failed" | "cleanup_failed" | undefined;
    let closed = false, cleanupDone = false, settled = false;
    let exitCode: number | null = null;
    let exitSignal: NodeJS.Signals | null = null;
    let killing: NodeJS.Timeout | undefined;
    let drain: NodeJS.Timeout | undefined;

    const killGroup = (kind: NodeJS.Signals) => {
      if (!child.pid) return;
      try { process.kill(-child.pid, kind); }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ESRCH") reason ??= "cleanup_failed";
      }
    };
    const finish = () => {
      if (settled || !closed || !cleanupDone) return;
      settled = true;
      clearTimeout(timeout);
      clearTimeout(killing);
      clearTimeout(drain);
      signal.removeEventListener("abort", abort);
      const captured = output.text();
      const status = reason === "cancelled" ? "Command interrupted; it may have had effects."
        : reason === "timeout" ? "Command timed out; it may have had effects."
        : reason === "spawn_failed" ? "Could not start the shell command."
        : reason === "cleanup_failed" ? "Command cleanup failed; descendants may still be running."
        : exitCode === 0 ? "Exit code: 0"
        : `Command failed. Exit code: ${exitCode ?? "none"}; signal: ${exitSignal ?? "none"}. It may have had effects.`;
      const result = `${status}\n${captured || "(no output)"}`;
      if (reason || exitCode !== 0) reject(new ToolFailure(result));
      else resolve(result);
    };
    const boundDrain = () => {
      if (drain || closed) return;
      // A deliberately detached descendant can escape our process group while
      // retaining pipes. Bound cleanup rather than hold the conversation forever.
      drain = setTimeout(() => {
        reason = "cleanup_failed";
        child.stdout.destroy();
        child.stderr.destroy();
        closed = true;
        finish();
      }, 1000);
    };
    const abort = () => stop("cancelled");
    const stop = (why: "cancelled" | "timeout") => {
      if (settled) return;
      reason ??= why;
      if (killing) return;
      killGroup("SIGTERM");
      // Do not settle on 'close' until escalation: descendants can close their
      // pipes yet ignore SIGTERM. Keep ownership until the group is cleaned up.
      killing = setTimeout(() => {
        killGroup("SIGKILL");
        cleanupDone = true;
        boundDrain();
        finish();
      }, 250);
    };
    const timeout = setTimeout(() => stop("timeout"), timeoutSeconds * 1000);
    child.stdout.on("data", (chunk: Buffer) => output.append(chunk));
    child.stderr.on("data", (chunk: Buffer) => output.append(chunk));
    const pipeError = () => { reason = "cleanup_failed"; stop("cancelled"); };
    child.stdout.once("error", pipeError);
    child.stderr.once("error", pipeError);
    child.once("error", () => {
      reason = "spawn_failed";
      if (!child.pid) cleanupDone = true;
      else stop("cancelled");
    });
    child.once("exit", () => {
      if (!killing) {
        // Even successful shells may leave background jobs. They are scoped to
        // this invocation, not a supported way to launch persistent services.
        killGroup("SIGKILL");
        cleanupDone = true;
        boundDrain();
      }
    });
    child.once("close", (code, terminationSignal) => {
      closed = true;
      exitCode = code;
      exitSignal = terminationSignal;
      finish();
    });
    signal.addEventListener("abort", abort, { once: true });
    if (signal.aborted) abort();
  });
}

export function createShellTool(): Tool {
  return {
    definition: {
      name: "shell",
      description: "Run an approved bash command in the workspace (not sandboxed), with bounded combined output. Default timeout 120 seconds, maximum 900. Commands are not retried; background jobs are terminated on completion.",
      parameters: schema({ command: { type: "string", minLength: 1 },
        timeout_seconds: { type: "integer", minimum: 1, maximum: 900 } }, ["command"]),
    },
    async prepare(args, context) {
      fields(args, ["command", "timeout_seconds"]);
      const command = string(args, "command");
      if (!command.trim()) throw new ToolFailure("Command must not be empty.");
      const timeout = integer(args, "timeout_seconds", 1, 900, 120);
      if (process.platform !== "darwin" && process.platform !== "linux") {
        throw new ToolFailure("Shell execution currently supports macOS and Linux only.");
      }
      const workspace = await Workspace.create(context.workspace, context.signal);
      return {
        approval: `Command:\n${command}\n\nDirectory: ${JSON.stringify(workspace.root)}\nTimeout: ${timeout} seconds`,
        async execute() {
          const directory = await workspace.path(".");
          return run(command, directory.path, timeout, context.signal);
        },
      };
    },
  };
}
