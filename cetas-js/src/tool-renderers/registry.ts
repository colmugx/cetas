/**
 * registry.ts — tool-renderer dispatch table.
 *
 * Mirrors pi-coding-agent's ToolDefinition renderCall/renderResult split,
 * but simplified: a renderer is just two optional functions returning a
 * pi-tui Component. The `fallback` renderer handles tools we don't know.
 *
 * Why not a class with virtual methods: TS discriminated unions + a record
 * give us the same dispatch with less ceremony, and a missing slot falls
 * through to `fallback` automatically.
 */

import type { Component } from "@earendil-works/pi-tui";
import { theme } from "../../ui/theme.ts";
import { fallbackRenderer } from "./fallback.ts";

export interface ToolRenderContext {
  toolCallId: string;
  args: unknown;
  cwd: string;
  /** Mutable per-row state (e.g. start-time for bash duration display). */
  state: Record<string, unknown>;
  /** True once `tool_call_started` arrived; false during args streaming. */
  executionStarted: boolean;
  /** True when args have fully parsed (always true in cetas — args arrive atomically). */
  argsComplete: boolean;
  /** True if the result is partial/streaming (always false in cetas today). */
  isPartial: boolean;
  /** True if the last result was an error. */
  isError: boolean;
  /** Force this tool row to re-render. */
  invalidate(): void;
  /** Previously returned component, if any — for diffing / reuse. */
  lastComponent?: Component;
}

export interface ToolRenderResultOptions {
  expanded: boolean;
  isPartial: boolean;
}

export interface ToolRenderer {
  /** Render the call (args) — called when the tool_call is started. */
  renderCall?(ctx: ToolRenderContext): Component;
  /** Render the result — called when tool_call_completed arrives. */
  renderResult?(
    result: { content: string; isError: boolean },
    options: ToolRenderResultOptions,
    ctx: ToolRenderContext,
  ): Component;
}

/** Render-state record — tool name → renderer. */
const REGISTRY: Record<string, ToolRenderer> = {};

/** Register a renderer. Call once at module load. */
export function registerToolRenderer(name: string, r: ToolRenderer): void {
  REGISTRY[name] = r;
}

/** Lookup with graceful fallback. */
export function pickToolRenderer(name: string): ToolRenderer {
  return REGISTRY[name] ?? fallbackRenderer;
}

/** Shared helpers for argument extraction (used by per-tool renderers). */
export function argString(args: unknown, key: string): string {
  if (args && typeof args === "object" && key in (args as Record<string, unknown>)) {
    const v = (args as Record<string, unknown>)[key];
    if (typeof v === "string") return v;
  }
  return "";
}

export function argNumber(args: unknown, key: string): number | undefined {
  if (args && typeof args === "object" && key in (args as Record<string, unknown>)) {
    const v = (args as Record<string, unknown>)[key];
    if (typeof v === "number") return v;
    if (typeof v === "string") {
      const n = Number(v);
      if (!Number.isNaN(n)) return n;
    }
  }
  return undefined;
}

export function argBool(args: unknown, key: string, defv = false): boolean {
  if (args && typeof args === "object" && key in (args as Record<string, unknown>)) {
    const v = (args as Record<string, unknown>)[key];
    if (typeof v === "boolean") return v;
  }
  return defv;
}

/** Truncate a string for one-line preview. */
export function truncateForPreview(s: string, max = 200): string {
  const oneLine = s.replace(/\n/g, " ");
  return oneLine.length > max ? oneLine.slice(0, max) + "…" : oneLine;
}

/** Bold tool-title prefix used by most renderers. */
export function toolTitle(name: string): string {
  return theme.toolTitle(name);
}
