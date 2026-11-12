import { randomUUID } from "node:crypto";
import { constants, type Stats } from "node:fs";
import { lstat, mkdir, open, readdir, realpath, rename, rmdir, unlink } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { validateRecord, validID, type ConversationRecord } from "../core/conversation-record.ts";

export interface ConversationStore {
  load(): Promise<ConversationRecord[]>;
  save(record: ConversationRecord): Promise<void>;
  delete(id: string): Promise<void>;
  close(): Promise<void>;
}

const LIMIT = 16 * 1024 * 1024;

// One private JSON file per conversation; no separate catalog to get out of sync.
// A profile is local, single-owner storage, not a shared/network database.
export class JsonConversationStore implements ConversationStore {
  private readonly root: string;
  private readonly lock: string;
  private readonly lockInfo: Stats;
  private tail: Promise<unknown> = Promise.resolve();
  private closed = false;

  private constructor(root: string, lockInfo: Stats) {
    this.root = root; this.lock = join(root, ".lock"); this.lockInfo = lockInfo;
  }

  static async open(directory: string): Promise<JsonConversationStore> {
    if (!isAbsolute(directory)) throw new Error("Profile directory must be absolute.");
    await mkdir(directory, { recursive: true, mode: 0o700 });
    const root = await realpath(directory);
    const lock = join(root, ".lock");
    try { await mkdir(lock, { mode: 0o700 }); }
    catch { throw new Error("Profile is locked or unavailable. Stop its owner before opening it; a crash lock requires explicit recovery."); }
    try {
      const owner = await open(join(lock, "owner"), "wx", 0o600);
      try { await owner.writeFile(`PID: ${process.pid}\n`); await owner.sync(); }
      finally { await owner.close(); }
      return new JsonConversationStore(root, await lstat(lock));
    } catch {
      await unlink(join(lock, "owner")).catch(() => {});
      await rmdir(lock).catch(() => {});
      throw new Error("Could not initialize profile ownership.");
    }
  }

  private async assertOwner(): Promise<void> {
    const info = await lstat(this.lock);
    if (!info.isDirectory() || info.isSymbolicLink() || info.ino !== this.lockInfo.ino || info.dev !== this.lockInfo.dev) {
      throw new Error("Profile ownership was lost.");
    }
  }

  private queue<T>(action: () => Promise<T>): Promise<T> {
    if (this.closed) return Promise.reject(new Error("Conversation store is closed."));
    const result = this.tail.then(async () => { await this.assertOwner(); return action(); });
    this.tail = result.catch(() => {});
    return result;
  }

  private file(id: string): string {
    if (!validID(id)) throw new Error("Invalid conversation ID.");
    return join(this.root, `${id}.json`);
  }

  private async syncDirectory(): Promise<void> {
    const directory = await open(this.root, constants.O_RDONLY | constants.O_DIRECTORY);
    try { await directory.sync(); } finally { await directory.close(); }
  }

  async load(): Promise<ConversationRecord[]> {
    return this.queue(async () => {
      const records: ConversationRecord[] = [];
      const names = (await readdir(this.root)).filter(name => name.endsWith(".json")).sort();
      for (const name of names) {
        const id = name.slice(0, -5);
        const file = await open(this.file(id), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
        try {
          const info = await file.stat();
          if (!info.isFile() || info.size > LIMIT) throw new Error("Invalid conversation file.");
          // Bound reads even if another process grows a file despite profile ownership.
          const data = Buffer.alloc(Math.min(info.size + 1, LIMIT + 1));
          let length = 0;
          while (length < data.length) {
            const read = await file.read(data, length, data.length - length, length);
            if (!read.bytesRead) break;
            length += read.bytesRead;
          }
          const latest = await file.stat();
          if (length !== info.size || latest.size !== info.size || latest.mtimeMs !== info.mtimeMs || latest.ctimeMs !== info.ctimeMs) {
            throw new Error("Conversation file changed during loading.");
          }
          const value: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(data.subarray(0, length)));
          const record = validateRecord(value);
          if (record.id !== id) throw new Error("Conversation filename does not match its ID.");
          records.push(record);
        } finally { await file.close(); }
      }
      return records;
    }).catch(() => { throw new Error("Could not load conversations. The profile may contain corrupt, unsupported, linked, or oversized data; it was not overwritten."); });
  }

  async save(value: ConversationRecord): Promise<void> {
    // Capture before queuing: subsequent streaming updates cannot mutate this write.
    const record = validateRecord(value);
    const data = Buffer.from(JSON.stringify(record));
    if (data.length > LIMIT) throw new Error("Conversation exceeds the 16 MiB checkpoint limit.");
    return this.queue(async () => {
      const target = this.file(record.id);
      const temporary = join(this.root, `.${record.id}.${randomUUID()}.tmp`);
      let staged = false;
      try {
        try {
          const info = await lstat(target);
          if (!info.isFile() || info.isSymbolicLink()) throw new Error("Invalid checkpoint target.");
        } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
        const file = await open(temporary, "wx", 0o600);
        staged = true;
        try { await file.writeFile(data); await file.sync(); }
        finally { await file.close(); }
        await this.assertOwner();
        await rename(temporary, target);
        await this.syncDirectory();
      } finally {
        if (staged) await unlink(temporary).catch(error => {
          if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
        });
      }
    }).catch(() => { throw new Error("Could not save conversation. Its last durable checkpoint must be inspected before continuing."); });
  }

  async delete(id: string): Promise<void> {
    const target = this.file(id);
    return this.queue(async () => {
      await unlink(target);
      await this.syncDirectory();
    }).catch(() => { throw new Error("Could not confirm conversation deletion. Inspect the profile before continuing."); });
  }

  close(): Promise<void> {
    const closing = this.queue(async () => {
      await unlink(join(this.lock, "owner"));
      await rmdir(this.lock);
    });
    this.closed = true;
    return closing;
  }
}
