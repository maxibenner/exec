import { constants } from "node:fs";
import { open } from "node:fs/promises";
import { join } from "node:path";
import { DeepSeekProvider } from "./deepseek.ts";

export interface CredentialOptions {
  profile: string;
  credentialsPath?: string;
  env?: NodeJS.ProcessEnv;
}

function apiKey(value: unknown): string {
  if (typeof value !== "string" || !value.trim() || value.trim().length > 8192
    || /[^\x21-\x7e]/.test(value.trim())) {
    throw new Error("Invalid DeepSeek API key. Supply a nonempty printable ASCII token.");
  }
  return value.trim();
}

// Credentials are loaded once at startup, not persisted in conversation state.
// Never attach raw filesystem/JSON errors: they can contain credential contents.
export async function loadDeepSeekAPIKey(options: CredentialOptions): Promise<string> {
  const env = options.env ?? process.env;
  if (env.DEEPSEEK_API_KEY !== undefined) return apiKey(env.DEEPSEEK_API_KEY);
  const path = options.credentialsPath ?? join(options.profile, "credentials.json");
  let file;
  try {
    file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const info = await file.stat();
    if (!info.isFile() || info.size > 16384 || (info.mode & 0o077) !== 0
      || (process.getuid && info.uid !== process.getuid())) throw new Error();
    // Bound the read even if another process grows the file after stat().
    const buffer = Buffer.alloc(16385);
    let size = 0;
    while (size < buffer.length) {
      const { bytesRead } = await file.read(buffer, size, buffer.length - size, null);
      if (!bytesRead) break;
      size += bytesRead;
    }
    if (size > 16384) throw new Error();
    const value: unknown = JSON.parse(buffer.subarray(0, size).toString("utf8"));
    if (!value || typeof value !== "object" || Array.isArray(value)
      || Object.keys(value).join() !== "deepseek") throw new Error();
    const deepseek = (value as Record<string, unknown>).deepseek;
    if (!deepseek || typeof deepseek !== "object" || Array.isArray(deepseek)
      || Object.keys(deepseek).join() !== "apiKey") throw new Error();
    return apiKey((deepseek as Record<string, unknown>).apiKey);
  } catch {
    throw new Error("Cannot load DeepSeek credentials. Set DEEPSEEK_API_KEY or supply an owned, private (0600) credentials JSON file with {\"deepseek\":{\"apiKey\":\"…\"}}.");
  } finally {
    await file?.close();
  }
}

export async function configuredDeepSeekProvider(options: CredentialOptions): Promise<DeepSeekProvider> {
  const key = await loadDeepSeekAPIKey(options);
  return new DeepSeekProvider({ getAPIKey: signal => { signal.throwIfAborted(); return key; } });
}
