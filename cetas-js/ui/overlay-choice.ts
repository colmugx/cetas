/**
 * One-shot bridge from a modal's callback lifecycle to an awaitable result.
 * A programmatic hide (including shutdown) always settles as cancellation.
 * No caller receives or needs a command-lock release callback.
 */
export class OverlayChoice<T> {
  private pending?: {
    settle(value: T | undefined): void;
  };

  get isPending(): boolean {
    return this.pending !== undefined;
  }

  wait(open: () => void, hide: () => void, signal?: AbortSignal): Promise<T | undefined> {
    if (this.pending !== undefined) throw new Error("an overlay choice is already pending");
    if (signal?.aborted) return Promise.resolve(undefined);
    return new Promise<T | undefined>((resolve, reject) => {
      const abort = () => {
        try {
          hide();
        } finally {
          this.cancel();
        }
      };
      const settle = (value: T | undefined) => {
        if (this.pending === undefined) return;
        this.pending = undefined;
        signal?.removeEventListener("abort", abort);
        resolve(value);
      };
      this.pending = { settle };
      signal?.addEventListener("abort", abort, { once: true });
      try {
        open();
        // Some hosts may synchronously dispatch cancellation while opening.
        if (signal?.aborted) abort();
      } catch (error: unknown) {
        if (this.pending !== undefined) {
          this.pending = undefined;
          signal?.removeEventListener("abort", abort);
          reject(error);
        }
      }
    });
  }

  select(value: T): void {
    this.pending?.settle(value);
  }

  cancel(): void {
    this.pending?.settle(undefined);
  }
}
