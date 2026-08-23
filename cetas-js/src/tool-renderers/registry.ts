/**
 * registry.ts — tool-renderer dispatch table + generic ToolRow engine.
 *
 * A renderer is two optional functions — renderCall and renderResult — each
 * returning a pi-tui Component. Dispatch order in `pickToolRenderer`:
 *   1. declarative spec table (specs.ts) via `specRenderer`
 *   2. registered hook (`registerToolRenderer`)
 *   3. `fallback` renderer for tools we don't know
 *
 * Why not a class with virtual methods: TS discriminated unions + a record
 * give us the same dispatch with less ceremony, and a missing slot falls
 * through to `fallback` automatically.
 */

import { Text, type Component } from "@earendil-works/pi-tui";
import { theme } from "../../ui/theme.ts";
import { fallbackRenderer } from "./fallback.ts";
import {
  TOOL_ROW_SPECS,
  summaryOf,
  type ArgSpec,
  type ToolRowSpec,
} from "./specs.ts";

export interface ToolRenderContext {
  toolCallId: string;
  toolName: string;
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

/** Result payload. `structured` carries ToolOutcome.structured from the bridge. */
export interface ToolRenderResultPayload {
  content: string;
  isError: boolean;
  structured?: unknown;
}

export interface ToolRenderer {
  /** Render the call (args) — called when the tool_call is started. */
  renderCall?(ctx: ToolRenderContext): Component;
  /** Render the result — called when tool_call_completed arrives. */
  renderResult?(
    result: ToolRenderResultPayload,
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

/** Lookup: spec table first, then registered hook, then graceful fallback. */
export function pickToolRenderer(name: string): ToolRenderer {
  const spec = TOOL_ROW_SPECS[name];
  if (spec) return specRenderer(spec);
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

/**
 * Traffic-light bullet for tool rows — one glyph family (●), colored by
 * state: amber while the tool runs, green on success, red on error.
 * Replaces the earlier →/✓/✗ arrow-and-emoji mix.
 */
export function statusBullet(state: "running" | "success" | "error"): string {
  if (state === "success") return theme.success("●");
  if (state === "error") return theme.error("●");
  return theme.warning("●");
}

/** Bullet state for a call view: error-colored once the call failed. */
export function callBullet(ctx: ToolRenderContext): string {
  return statusBullet(ctx.isError ? "error" : "running");
}

/** Bold tool-title prefix used by most renderers. */
export function toolTitle(name: string): string {
  return theme.toolTitle(name);
}

// -- generic spec engine ---------------------------------------------------

/**
 * First key hit coerced to a display string ("true"/"false" for booleans),
 * mapped through the spec's render, else the spec's fallback. Empty-string
 * values count as no hit so `path: ""` falls back like the old renderers.
 */
function specSegment(s: ArgSpec, args: unknown): string | undefined {
  if (args && typeof args === "object") {
    const record = args as Record<string, unknown>;
    for (const key of s.keys) {
      if (!(key in record)) continue;
      const v = record[key];
      let text: string | undefined;
      if (typeof v === "string") text = v;
      else if (typeof v === "boolean") text = v ? "true" : "false";
      else if (typeof v === "number") text = String(v);
      if (text === undefined || text === "") continue;
      return s.render ? s.render(text, args) : text;
    }
  }
  return s.fallback;
}

function specSegments(specs: ArgSpec[], args: unknown): string[] {
  return specs
    .map((s) => specSegment(s, args))
    .filter((t): t is string => t !== undefined);
}

/**
 * Turn a declarative ToolRowSpec into a ToolRenderer.
 *
 * Call view:    `●(amber) title <primary joined by space>  <secondary muted>`
 * Result view:  `●(green/red) title <primary>` + 6-space-indented summary
 *               lines. Summary chain: spec.summarize → structured.summary →
 *               truncated content; errors always show truncated content.
 */
export function specRenderer(spec: ToolRowSpec): ToolRenderer {
  const primaryText = (ctx: ToolRenderContext): string =>
    specSegments(spec.primary, ctx.args).join(" ");
  return {
    renderCall(ctx: ToolRenderContext): Component {
      const title = toolTitle(spec.title ?? ctx.toolName);
      const primary = primaryText(ctx);
      const secondary = specSegments(spec.secondary ?? [], ctx.args)
        .map((t) => theme.muted(t))
        .join(" ");
      let line = `${callBullet(ctx)} ${title}`;
      if (primary) line += ` ${primary}`;
      if (secondary) line += `  ${secondary}`;
      return new Text(line, 1, 0);
    },
    renderResult(
      result: ToolRenderResultPayload,
      _options: ToolRenderResultOptions,
      ctx: ToolRenderContext,
    ): Component {
      const title = toolTitle(spec.title ?? ctx.toolName);
      const primary = primaryText(ctx);
      const line1 =
        `${statusBullet(result.isError ? "error" : "success")} ${title}` +
        (primary ? ` ${primary}` : "");
      const summary = result.isError
        ? truncateForPreview(result.content, 200)
        : spec.summarize?.({
            content: result.content,
            structured: result.structured,
          }) ??
          summaryOf(result.structured) ??
          truncateForPreview(result.content);
      if (!summary) return new Text(line1, 1, 0);
      const indented = summary
        .split("\n")
        .map((l) => theme.muted(l))
        .join("\n      ");
      return new Text(`${line1}\n      ${indented}`, 1, 0);
    },
  };
}
