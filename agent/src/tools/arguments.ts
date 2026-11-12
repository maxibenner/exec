import type { Json, ToolCall } from "../core/types.ts";
import { ToolFailure } from "../core/tool-failure.ts";

type Arguments = ToolCall["arguments"];

export function fields(args: Arguments, allowed: string[]): void {
  if (Object.keys(args).some(key => !allowed.includes(key))) throw new ToolFailure("Unexpected tool argument.");
}

export function string(args: Arguments, key: string, limit = 32768): string {
  const value = args[key];
  if (typeof value !== "string" || value.includes("\0") || Buffer.byteLength(value) > limit) {
    throw new ToolFailure(`${key} must be a string without NUL bytes, at most ${limit} UTF-8 bytes.`);
  }
  return value;
}

export function integer(args: Arguments, key: string, minimum: number, maximum: number, fallback?: number): number {
  const value = args[key] === undefined ? fallback : args[key];
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new ToolFailure(`${key} must be an integer between ${minimum} and ${maximum}.`);
  }
  return value;
}

export function schema(properties: { [key: string]: Json }, required = Object.keys(properties)): { [key: string]: Json } {
  return { type: "object", properties, required, additionalProperties: false };
}
