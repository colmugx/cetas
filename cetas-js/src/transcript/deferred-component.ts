import type { Component } from "@earendil-works/pi-tui";
import type { SearchableComponent } from "./search-index.ts";

/**
 * Lightweight immutable replay descriptor. Instantiate pi-tui Markdown/
 * ToolRow and their render caches only when the message reaches the viewport.
 * Once mounted its instance is retained to preserve native folding/state.
 */
export class DeferredTranscriptComponent implements SearchableComponent {
  private delegate?: Component;

  constructor(private readonly build: () => Component, private readonly sourceText: string | (() => string) = "") {}

  render(width: number): string[] {
    this.delegate ??= this.build();
    return this.delegate.render(width);
  }

  invalidate(): void {
    this.delegate?.invalidate();
  }

  getSearchText(): string { return typeof this.sourceText === "function" ? this.sourceText() : this.sourceText; }

  /** No materialized markup outside the viewport until first visible. */
  get isMaterialized(): boolean {
    return this.delegate !== undefined;
  }
}
