/**
 * layout.ts — layout components for cetas-js.
 *
 * DebugFooter: bottom status bar showing model name (left) and live debug
 * counters (right). Designed to be mutated from the event loop so the user
 * sees real-time turn/tool/token/latency data during development.
 */

import { Container, Text } from "@earendil-works/pi-tui";
import { theme } from "./theme.ts";

export interface DebugInfo {
  model: string;
  turnCount: number;
  toolsThisTurn: number;
  tokensInput: number;
  tokensOutput: number;
  sessionId: string;
  latencyMs: number;
}

export function defaultDebugInfo(model: string): DebugInfo {
  return {
    model,
    turnCount: 0,
    toolsThisTurn: 0,
    tokensInput: 0,
    tokensOutput: 0,
    sessionId: "—",
    latencyMs: 0,
  };
}

/**
 * Footer bar — model name on the left, debug counters on the right.
 * Call `update(info)` whenever the tracked stats change; the component
 * diffs into the existing render via pi-tui's text setter.
 */
export class DebugFooter extends Container {
  private textEl: Text;

  constructor(model: string) {
    super();
    this.textEl = new Text("", 1, 0);
    this.addChild(this.textEl);
    this.renderInfo(defaultDebugInfo(model));
  }

  update(info: DebugInfo): void {
    this.renderInfo(info);
  }

  private renderInfo(info: DebugInfo): void {
    const left = theme.bold(` ${info.model} `);
    const right = [
      `turn: ${info.turnCount}`,
      `tools: ${info.toolsThisTurn}`,
      `tok: ${info.tokensInput}↑ ${info.tokensOutput}↓`,
      `session: ${info.sessionId}`,
      `lat: ${info.latencyMs}ms`,
    ].join(" | ");
    this.textEl.setText(left + theme.muted(right));
    this.invalidate();
  }
}
