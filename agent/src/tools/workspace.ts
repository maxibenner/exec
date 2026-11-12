import { createHash } from "node:crypto";
import { constants, type Stats } from "node:fs";
import { lstat, open, opendir, realpath } from "node:fs/promises";
import { isAbsolute, join, resolve, sep } from "node:path";
import { ToolFailure } from "../core/tool-failure.ts";

export const FILE_LIMIT = 1024 * 1024;
export const OUTPUT_LIMIT = 32 * 1024;
export const revision = (data: Uint8Array): string => createHash("sha256").update(data).digest("hex");
export const sameFile = (a: Stats, b: Stats): boolean => a.dev === b.dev && a.ino === b.ino;
export const unchanged = (a: Stats, b: Stats): boolean => sameFile(a, b)
  && a.size === b.size && a.mtimeMs === b.mtimeMs && a.ctimeMs === b.ctimeMs
  && a.mode === b.mode && a.uid === b.uid && a.gid === b.gid;

export function text(data: Uint8Array): string {
  if (data.includes(0)) throw new ToolFailure("File contains NUL bytes; only UTF-8 text is supported.");
  try { return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(data); }
  catch { throw new ToolFailure("File is not valid UTF-8 text."); }
}

export function relativePath(path: string): string {
  if (!path || isAbsolute(path) || path.includes("\0") || path.includes("\\")
    || Buffer.byteLength(path) > 4096 || path.split("/").includes("..")) {
    throw new ToolFailure("Use a relative workspace path without '..' or backslashes.");
  }
  return path.split("/").filter(part => part && part !== ".").join("/") || ".";
}

export interface TextFile { data: Buffer; info: Stats }

// Node has no portable openat API. Check every path component and refuse symlinks,
// then use O_NOFOLLOW for file opens. This is not a hostile-filesystem sandbox:
// an external process can still race ancestor replacement between path-based calls.
export class Workspace {
  readonly root: string;
  private readonly identity: Stats;
  private readonly signal: AbortSignal;

  private constructor(root: string, identity: Stats, signal: AbortSignal) {
    this.root = root; this.identity = identity; this.signal = signal;
  }

  static async create(root: string, signal: AbortSignal): Promise<Workspace> {
    signal.throwIfAborted();
    if (!isAbsolute(root)) throw new ToolFailure("Workspace must be an absolute directory path.");
    // Canonicalize the user-selected root, including macOS /var -> /private/var.
    const canonical = await realpath(root);
    const info = await lstat(canonical);
    if (!info.isDirectory()) throw new ToolFailure("Workspace must be a directory.");
    return new Workspace(canonical, info, signal);
  }

  async path(path: string, allowMissing = false): Promise<{ path: string; info: Stats | null }> {
    this.signal.throwIfAborted();
    const relative = relativePath(path);
    const target = resolve(this.root, relative);
    const parts = target.split(sep).filter(Boolean);
    let current: string = sep;
    let info = await lstat(current);
    let foundRoot = this.root === sep;
    if (foundRoot && !sameFile(info, this.identity)) throw new ToolFailure("Workspace changed.");
    for (let index = 0; index < parts.length; index++) {
      this.signal.throwIfAborted();
      current = join(current, parts[index]!);
      try { info = await lstat(current); }
      catch (error) {
        if (allowMissing && index === parts.length - 1 && foundRoot
          && (error as NodeJS.ErrnoException).code === "ENOENT") return { path: target, info: null };
        throw error;
      }
      if (info.isSymbolicLink()) throw new ToolFailure("Symlinks are not followed by workspace file tools.");
      if (index < parts.length - 1 && !info.isDirectory()) throw new ToolFailure("Parent path must be a directory.");
      if (current === this.root) {
        if (!sameFile(info, this.identity) || !info.isDirectory()) throw new ToolFailure("Workspace changed.");
        foundRoot = true;
      }
    }
    if (!foundRoot) throw new ToolFailure("Path is outside the workspace.");
    return { path: target, info };
  }

  async read(path: string): Promise<TextFile> {
    const checked = await this.path(path);
    if (!checked.info?.isFile() || checked.info.size > FILE_LIMIT) {
      throw new ToolFailure("Read requires a regular UTF-8 file of at most 1 MiB.");
    }
    const file = await open(checked.path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
      const info = await file.stat();
      if (!info.isFile() || info.size > FILE_LIMIT || !sameFile(info, checked.info)) {
        throw new ToolFailure("File changed or is not a regular file of at most 1 MiB.");
      }
      const buffer = Buffer.alloc(FILE_LIMIT + 1);
      let size = 0;
      while (size < buffer.length) {
        this.signal.throwIfAborted();
        const read = await file.read(buffer, size, Math.min(65536, buffer.length - size), size);
        if (!read.bytesRead) break;
        size += read.bytesRead;
      }
      if (size > FILE_LIMIT) throw new ToolFailure("File exceeds 1 MiB.");
      const latest = await this.path(path);
      if (!latest.info || !unchanged(info, await file.stat()) || !unchanged(info, latest.info)) {
        throw new ToolFailure("File changed during reading; read it again.");
      }
      const data = Buffer.from(buffer.subarray(0, size));
      text(data);
      return { data, info };
    } finally { await file.close(); }
  }

  async entries(path: string): Promise<{ names: string[]; truncated: boolean }> {
    const checked = await this.path(path);
    if (!checked.info?.isDirectory()) throw new ToolFailure("Choose a directory.");
    const names: string[] = [];
    let truncated = false;
    const directory = await opendir(checked.path);
    for await (const entry of directory) {
      this.signal.throwIfAborted();
      if (names.length === 2000) { truncated = true; break; }
      names.push(entry.name);
    }
    const latest = await this.path(path);
    if (!latest.info || !sameFile(checked.info, latest.info)) throw new ToolFailure("Directory changed during listing.");
    return { names: names.sort(), truncated };
  }
}
