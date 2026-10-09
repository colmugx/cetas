/**
 * wakeup-header.ts — ambient signals for core-initiated activity, mounted
 * above the input next to the subagent header (never inside the transcript
 * body, never styled as user-typed input):
 *
 *     ⧗ 2 background results pending delivery
 *     ◌ wakeup build-watch · running (environment)
 *
 * `background results pending delivery` counts ready-but-undelivered
 * subagent receipts (from `posoco.tasks`), not wakeup tickets — one merged
 * ticket can carry several results and an executing ticket does not mean
 * every result was injected. Wakeup lines come from the executing tickets
 * of the frozen `posoco.wakeup` projection. The component re-reads its
 * source on every render, so the signal restores itself after transcript
 * rebuilds without replay support. Bounded: at most three wakeup lines plus
 * one overflow aggregate.
 */

import { type Component, truncateToWidth } from "@earendil-works/pi-tui";

import { theme } from "./theme.ts";
import type { WakeupTicket } from "../src/controllers/wakeup-activity.ts";

const MAX_WAKEUP_LINES = 3;

export interface WakeupHeaderSource {
  readonly executing: readonly WakeupTicket[];
  readonly resultsWaiting: number;
}

/** Content-only projection (width applied at render time). */
export function wakeupHeaderLines(source: WakeupHeaderSource): string[] {
  const lines: string[] = [];
  if (source.resultsWaiting > 0) {
    lines.push(
      `⧗ ${source.resultsWaiting} background result${source.resultsWaiting === 1 ? "" : "s"} pending delivery`,
    );
  }
  for (const ticket of source.executing.slice(0, MAX_WAKEUP_LINES)) {
    lines.push(`◌ wakeup ${ticket.tag} · running (environment)`);
  }
  const overflow = source.executing.length - MAX_WAKEUP_LINES;
  if (overflow > 0) lines.push(`◌ +${overflow} more wakeups`);
  return lines;
}

export function renderWakeupHeader(
  source: WakeupHeaderSource,
  width: number,
): string[] {
  if (width <= 0) return [];
  return wakeupHeaderLines(source).map((line) =>
    theme.muted(truncateToWidth(line, width)),
  );
}

/** Live component; the shell decides when a re-render is worth it. */
export class WakeupHeader implements Component {
  constructor(private readonly source: () => WakeupHeaderSource | undefined) {}

  render(width: number): string[] {
    const source = this.source();
    if (source === undefined) return [];
    return renderWakeupHeader(source, width);
  }

  handleInput(_data: string): void {}

  invalidate(): void {}
}
