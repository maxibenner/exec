import type { Tool } from "../core/types.ts";
import { createFileTools } from "./files.ts";
import { createShellTool } from "./shell.ts";

export function createWorkspaceTools(): Tool[] {
  return [...createFileTools(), createShellTool()];
}
