import { ProviderFailure } from "../core/provider-failure.ts";

async function* bytes(body: ReadableStream<Uint8Array>, signal: AbortSignal, limit: number): AsyncGenerator<Uint8Array> {
  signal.throwIfAborted();
  const reader = body.getReader();
  const abort = () => { void reader.cancel().catch(() => {}); };
  signal.addEventListener("abort", abort, { once: true });
  let size = 0;
  try {
    while (true) {
      signal.throwIfAborted();
      const next = await reader.read();
      signal.throwIfAborted();
      if (next.done) return;
      size += next.value.byteLength;
      if (size > limit) throw new ProviderFailure("response");
      yield next.value;
    }
  } finally {
    signal.removeEventListener("abort", abort);
    try { await reader.cancel(); } catch { /* No retry; discard any unread response. */ }
    reader.releaseLock();
  }
}

// SSE framing only, not a reconnecting client. Handles split UTF-8, CR/LF/CRLF,
// comments and multiple data lines. Incomplete final events are not dispatched.
export async function* readSSE(body: ReadableStream<Uint8Array>, signal: AbortSignal): AsyncGenerator<string> {
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let line = "", data: string[] = [], eventBytes = 0, skipLF = false;
  function* feed(input: string): Generator<string> {
    for (const character of input) {
      if (skipLF) { skipLF = false; if (character === "\n") continue; }
      eventBytes += Buffer.byteLength(character);
      if (eventBytes > 256 * 1024) throw new ProviderFailure("response");
      if (character !== "\r" && character !== "\n") { line += character; continue; }
      skipLF = character === "\r";
      if (line === "") {
        const event = data.length ? data.join("\n") : undefined;
        data = []; eventBytes = 0;
        if (event !== undefined) yield event;
      } else {
        const colon = line.indexOf(":");
        const field = colon < 0 ? line : line.slice(0, colon);
        let value = colon < 0 ? "" : line.slice(colon + 1);
        if (value.startsWith(" ")) value = value.slice(1);
        if (field === "data") data.push(value);
      }
      line = "";
    }
  }
  for await (const chunk of bytes(body, signal, 16 * 1024 * 1024)) {
    let decoded: string;
    try { decoded = decoder.decode(chunk, { stream: true }); }
    catch { throw new ProviderFailure("response"); }
    yield* feed(decoded);
  }
  let remaining: string;
  try { remaining = decoder.decode(); } catch { throw new ProviderFailure("response"); }
  yield* feed(remaining);
}

export async function readJSON(body: ReadableStream<Uint8Array>, signal: AbortSignal): Promise<unknown> {
  const chunks: Uint8Array[] = [];
  for await (const chunk of bytes(body, signal, 128 * 1024)) chunks.push(chunk);
  try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks))); }
  catch { throw new ProviderFailure("response"); }
}
