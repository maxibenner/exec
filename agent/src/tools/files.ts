import { randomUUID } from "node:crypto";
import { constants } from "node:fs";
import { link, lstat, open, rename, unlink } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { PreparedTool, Tool, ToolCall, ToolContext } from "../core/types.ts";
import { ToolFailure } from "../core/tool-failure.ts";
import { fields, integer, schema, string } from "./arguments.ts";
import { FILE_LIMIT, OUTPUT_LIMIT, Workspace, relativePath, revision, text, unchanged } from "./workspace.ts";

// Serialize our own final revision checks and writes across all conversations.
// Shell commands and external editors are not part of this lock.
let writes = Promise.resolve();
async function exclusive<T>(action: () => Promise<T>): Promise<T> {
  const previous = writes;
  let release!: () => void;
  writes = new Promise<void>(resolve => { release = resolve; });
  await previous;
  try { return await action(); } finally { release(); }
}

async function prepareEdit(args: ToolCall["arguments"], context: ToolContext): Promise<PreparedTool> {
  fields(args, ["path", "expected_revision", "old_text", "new_text"]);
  const path = relativePath(string(args, "path", 4096));
  if (path === ".") throw new ToolFailure("Choose a file, not the workspace root.");
  const expected = string(args, "expected_revision", 64);
  const oldText = string(args, "old_text");
  const newText = string(args, "new_text");
  const workspace = await Workspace.create(context.workspace, context.signal);
  const initial = await workspace.path(path, true);
  const before = initial.info ? await workspace.read(path) : null;
  if (before) {
    if (expected !== revision(before.data)) throw new ToolFailure("Revision mismatch. Read the file again before proposing an edit. Nothing was written.");
    if ((before.info.mode & 0o6000) !== 0 || before.info.nlink !== 1) {
      throw new ToolFailure("Cannot edit set-ID or multiply linked files.");
    }
  } else if (expected !== "new" || oldText !== "") {
    throw new ToolFailure("Creation requires expected_revision 'new', empty old_text, and an existing parent directory.");
  }
  const original = before ? text(before.data) : "";
  let after: string;
  if (oldText === "") {
    if (original !== "") throw new ToolFailure("old_text must match one nonempty block in an existing file.");
    after = newText;
  } else {
    const index = original.indexOf(oldText);
    if (index < 0 || original.indexOf(oldText, index + 1) >= 0) {
      throw new ToolFailure("old_text must match exactly once, including overlapping matches.");
    }
    after = original.slice(0, index) + newText + original.slice(index + oldText.length);
  }
  const data = Buffer.from(after);
  if ((before && before.data.equals(data)) || data.length > FILE_LIMIT) {
    throw new ToolFailure("Edit is unchanged or exceeds 1 MiB.");
  }
  const approval = `${before ? "Edit" : "Create"} ${JSON.stringify(path)}\nRevision: ${expected}\nReplace exact text:\n${JSON.stringify(oldText)}\nWith:\n${JSON.stringify(newText)}`
    + (before ? "\nMetadata: preserves POSIX owner/group/mode only; ACLs and extended attributes are not retained." : "");
  if (Buffer.byteLength(approval) > 65536) throw new ToolFailure("Approval exceeds 64 KiB. Propose a smaller edit.");

  return {
    approval,
    execute: () => exclusive(async () => {
      context.signal.throwIfAborted();
      const parent = await workspace.path(dirname(path));
      const staged = join(parent.path, `.exec-edit-${randomUUID()}`);
      let created = false;
      try {
        const stage = await open(staged, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
        created = true;
        try {
          await stage.writeFile(data);
          if (before) {
            // Preserve POSIX owner/group/mode. ACLs and extended attributes are not
            // copied by this portable implementation; see README for the limitation.
            await stage.chown(before.info.uid, before.info.gid);
            await stage.chmod(before.info.mode & 0o777);
          }
          await stage.sync();
        } finally { await stage.close(); }
        const current = await workspace.path(path, true);
        if (before) {
          if (!current.info) throw new ToolFailure("File disappeared while approval was pending. Nothing was written to the target.");
          const latest = await workspace.read(path);
          if (!unchanged(before.info, latest.info) || !before.data.equals(latest.data)) {
            throw new ToolFailure("File changed while approval was pending. Nothing was written to the target; read it again.");
          }
        } else if (current.info) {
          throw new ToolFailure("New file path is no longer available. Nothing was overwritten.");
        }
        const currentParent = await workspace.path(dirname(path));
        if (!currentParent.info || !parent.info || currentParent.info.ino !== parent.info.ino || currentParent.info.dev !== parent.info.dev) {
          throw new ToolFailure("Parent directory changed. Nothing was written to the target.");
        }
        context.signal.throwIfAborted();
        if (before) await rename(staged, current.path);
        else await link(staged, current.path); // Atomic no-overwrite creation.
        return `Edited ${JSON.stringify(path)}. Revision: ${revision(data)}`;
      } finally {
        if (created) await unlink(staged).catch(error => {
          if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
        });
      }
    }),
  };
}

async function list(workspace: Workspace, path: string, signal: AbortSignal): Promise<string> {
  const listing = await workspace.entries(path);
  const directory = await workspace.path(path);
  let output = "";
  let truncated = listing.truncated;
  for (const name of listing.names) {
    signal.throwIfAborted();
    const info = await lstat(join(directory.path, name));
    const line = `${JSON.stringify(name)}${info.isDirectory() ? "/" : info.isSymbolicLink() ? " [symlink; not followed]" : ""}\n`;
    if (Buffer.byteLength(output) + Buffer.byteLength(line) > OUTPUT_LIMIT - 256) { truncated = true; break; }
    output += line;
  }
  return (output || "(empty directory)\n") + (truncated ? "[Listing truncated; choose a narrower directory.]" : "");
}

async function read(workspace: Workspace, path: string, start: number, end: number): Promise<string> {
  const file = await workspace.read(path);
  const lines = text(file.data).split("\n");
  let output = `Revision: ${revision(file.data)}\n`;
  if (start > lines.length) return output + `Requested range is past end of file (${lines.length} lines).`;
  for (let index = start - 1; index < Math.min(end, lines.length); index++) {
    const line = `${index + 1}: ${lines[index]}\n`;
    if (Buffer.byteLength(output) + Buffer.byteLength(line) > OUTPUT_LIMIT - 128) return output + "[Output truncated at 32 KiB.]";
    output += line;
  }
  return output;
}

async function search(workspace: Workspace, path: string, query: string, signal: AbortSignal): Promise<string> {
  const pending: [string, number][] = [[path, 0]];
  let visited = 0, matches = 0;
  let output = "", incomplete = false;
  const deadline = performance.now() + 5000;
  // Fail invalid starting directories rather than reporting a successful empty search.
  const initial = await workspace.path(path);
  if (!initial.info?.isDirectory()) throw new ToolFailure("Choose a search directory.");
  scan: while (pending.length) {
    signal.throwIfAborted();
    const [directory, depth] = pending.pop()!;
    if (visited >= 2000 || performance.now() >= deadline) { incomplete = true; break; }
    let listing;
    try { listing = await workspace.entries(directory); }
    catch { signal.throwIfAborted(); incomplete = true; continue; }
    incomplete ||= listing.truncated;
    for (const name of listing.names) {
      signal.throwIfAborted();
      if (++visited > 2000 || performance.now() >= deadline) { incomplete = true; break scan; }
      if (name.startsWith(".") || name === "node_modules" || name === "dist") continue;
      const child = directory === "." ? name : `${directory}/${name}`;
      try {
        const checked = await workspace.path(child);
        if (checked.info?.isDirectory()) {
          if (depth < 16) pending.push([child, depth + 1]); else incomplete = true;
        } else {
          const lines = text((await workspace.read(child)).data).split("\n");
          for (let index = 0; index < lines.length; index++) {
            if (!lines[index]!.includes(query)) continue;
            const line = `${JSON.stringify(child)}:${index + 1}: ${lines[index]}\n`;
            if (matches >= 100 || Buffer.byteLength(output) + Buffer.byteLength(line) > OUTPUT_LIMIT - 256) {
              incomplete = true; break scan;
            }
            output += line; matches++;
          }
        }
      } catch { signal.throwIfAborted(); incomplete = true; }
    }
  }
  return (output || "No matches in searched files.\n")
    + (incomplete ? "[Search incomplete: limits reached or unreadable, oversized, binary, or linked files skipped.]" : "");
}

export function createFileTools(): Tool[] {
  return [
    {
      definition: { name: "list_files", description: "List one workspace directory. Symlinks are not followed. Output is bounded.",
        parameters: schema({ path: { type: "string" } }) },
      async prepare(args, context) {
        fields(args, ["path"]);
        const path = relativePath(string(args, "path", 4096));
        const workspace = await Workspace.create(context.workspace, context.signal);
        return { approval: null, execute: () => list(workspace, path, context.signal) };
      },
    },
    {
      definition: { name: "read_file", description: "Read 1–400 lines of a UTF-8 file up to 1 MiB, with its full-file revision. Output is bounded to 32 KiB.",
        parameters: schema({ path: { type: "string" }, start_line: { type: "integer", minimum: 1 }, end_line: { type: "integer", minimum: 1 } }) },
      async prepare(args, context) {
        fields(args, ["path", "start_line", "end_line"]);
        const path = relativePath(string(args, "path", 4096));
        const start = integer(args, "start_line", 1, Number.MAX_SAFE_INTEGER);
        const end = integer(args, "end_line", start, Math.min(Number.MAX_SAFE_INTEGER, start + 399));
        const workspace = await Workspace.create(context.workspace, context.signal);
        return { approval: null, execute: () => read(workspace, path, start, end) };
      },
    },
    {
      definition: { name: "search_text", description: "Bounded case-sensitive literal search. Skips hidden entries, node_modules, dist, symlinks, binary and oversized files; reports incomplete searches.",
        parameters: schema({ path: { type: "string" }, query: { type: "string", minLength: 1 } }) },
      async prepare(args, context) {
        fields(args, ["path", "query"]);
        const path = relativePath(string(args, "path", 4096));
        const query = string(args, "query", 4096);
        if (!query || /[\r\n]/.test(query)) throw new ToolFailure("Search requires a nonempty single-line literal.");
        const workspace = await Workspace.create(context.workspace, context.signal);
        return { approval: null, execute: () => search(workspace, path, query, context.signal) };
      },
    },
    {
      definition: { name: "edit_file", description: "Propose one exact replacement, requiring approval. Read first and supply its revision. For creation, use expected_revision 'new' and empty old_text; parent must exist.",
        parameters: schema({ path: { type: "string" }, expected_revision: { type: "string" }, old_text: { type: "string" }, new_text: { type: "string" } }) },
      prepare: prepareEdit,
    },
  ];
}
