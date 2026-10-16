import type { Component } from "@earendil-works/pi-tui";

/**
 * Lightweight immutable replay descriptor. Instantiate pi-tui Markdown/
 * ToolRow and their render caches only when the message reaches the viewport.
 * Once mounted its instance is retained to preserve native folding/state.
 */
export class DeferredTranscriptComponent implements Component {
  private delegate?: Component;

  constructor(private readonly build: () => Component) {}

  render(width: number): string[] {
    this.delegate ??= this.build();
    return this.delegate.render(width);
  }

  invalidate(): void {
    this.delegate?.invalidate();
  }

  /** No materialized markup outside the viewport until first visible. */
  get isMaterialized(): boolean {
    return this.delegate !== undefined;
  }
}
