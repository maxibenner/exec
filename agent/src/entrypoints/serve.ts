import { configuredDeepSeekProvider, type CredentialOptions } from "../providers/credentials.ts";
import { startPersistentService } from "../service/persistent-service.ts";

// Standalone composition root; embedded hosts can still supply any ChatProvider.
export async function serve(options: CredentialOptions & { workspaceTools?: boolean }): Promise<void> {
  const provider = await configuredDeepSeekProvider(options);
  let stop!: () => void;
  const stopped = new Promise<void>(resolve => { stop = resolve; });
  // A signal during startup also takes the normal cleanup path. Repeated
  // signals never start duplicate closes or forcibly abandon active tools.
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
  try {
    let service;
    try { service = await startPersistentService({ ...options, provider }); }
    catch { throw new Error("Service startup failed. Check profile permissions, socket, and store lock; stale state is never removed automatically."); }
    await stopped;
    try { await service.close(); }
    catch { throw new Error("Service shutdown failed. Inspect the profile before restarting."); }
  } finally {
    process.off("SIGINT", stop);
    process.off("SIGTERM", stop);
  }
}
