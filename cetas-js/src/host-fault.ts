/**
 * Host-process fault policy.
 *
 * `uncaughtException`/`unhandledRejection` always record full detail to the
 * crash file and surface a notice on the live transcript. The one exception:
 * a torn-down terminal. pi-tui's renderer stops the terminal (raw mode off,
 * stdin listener removed) before throwing on an oversize line, so a fault
 * after that point leaves a host that can neither repaint nor read input —
 * it must exit instead of running on as a painted zombie holding the tty.
 */
import type { Terminal } from "@earendil-works/pi-tui";

/** Terminal wrapper that remembers the last lifecycle transition. */
export class TrackedTerminal implements Terminal {
  terminalStopped = false;

  constructor(private readonly inner: Terminal) {}

  start(onInput: (data: string) => void, onResize: () => void): void {
    this.terminalStopped = false;
    this.inner.start(onInput, onResize);
  }

  stop(): void {
    this.terminalStopped = true;
    this.inner.stop();
  }

  async drainInput(maxMs?: number, idleMs?: number): Promise<void> {
    await this.inner.drainInput(maxMs, idleMs);
  }

  write(data: string): void {
    this.inner.write(data);
  }

  get columns(): number {
    return this.inner.columns;
  }

  get rows(): number {
    return this.inner.rows;
  }

  get kittyProtocolActive(): boolean {
    return this.inner.kittyProtocolActive;
  }

  moveBy(lines: number): void {
    this.inner.moveBy(lines);
  }

  hideCursor(): void {
    this.inner.hideCursor();
  }

  showCursor(): void {
    this.inner.showCursor();
  }

  clearLine(): void {
    this.inner.clearLine();
  }

  clearFromCursor(): void {
    this.inner.clearFromCursor();
  }

  clearScreen(): void {
    this.inner.clearScreen();
  }

  setTitle(title: string): void {
    this.inner.setTitle(title);
  }

  setProgress(active: boolean): void {
    this.inner.setProgress(active);
  }
}

export interface UnhandledFaultHooks {
  /** Record the full fault detail; returns the short notice to show. */
  report(kind: string, error: unknown): string;
  /** Show the notice on the live surface — the TUI is still interactive. */
  surface(notice: string): void;
  /** Exit the process — the terminal is gone and nothing can be shown. */
  exitFatal(notice: string): void;
  isTerminalStopped(): boolean;
}

export function makeUnhandledFaultHandler(
  hooks: UnhandledFaultHooks,
): (kind: string, error: unknown) => void {
  return (kind, error) => {
    const notice = hooks.report(kind, error);
    if (hooks.isTerminalStopped()) {
      hooks.exitFatal(notice);
      return;
    }
    hooks.surface(notice);
  };
}
