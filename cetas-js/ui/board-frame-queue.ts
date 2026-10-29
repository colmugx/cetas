/**
 * Bounded FIFO for one Board WebSocket. Unlike a Promise chain, queued raw
 * frames are dropped immediately when the tab disconnects or exceeds budget.
 * Only the currently executing backend command may continue after close.
 */
export const BOARD_MAX_FRAME_CHARS = 1024 * 1024;
export const BOARD_MAX_QUEUED_FRAMES = 32;
export const BOARD_MAX_QUEUED_CHARS = 2 * 1024 * 1024;

export class BoardFrameQueue {
  private readonly frames: string[] = [];
  private queuedChars = 0;
  private running = false;
  private closed = false;

  private readonly handle: (text: string) => Promise<void>;
  private readonly onError: (error: unknown, text: string) => void;

  // The npm channel runs this .ts file directly under Node's strip-only
  // loader, which cannot transform TypeScript parameter properties.
  constructor(
    handle: (text: string) => Promise<void>,
    onError: (error: unknown, text: string) => void,
  ) {
    this.handle = handle;
    this.onError = onError;
  }

  enqueue(text: string): boolean {
    if (
      this.closed ||
      text.length > BOARD_MAX_FRAME_CHARS ||
      this.frames.length >= BOARD_MAX_QUEUED_FRAMES ||
      this.queuedChars + text.length > BOARD_MAX_QUEUED_CHARS
    ) return false;
    this.frames.push(text);
    this.queuedChars += text.length;
    if (!this.running) {
      this.running = true;
      void this.drain();
    }
    return true;
  }

  close(): void {
    this.closed = true;
    this.frames.length = 0;
    this.queuedChars = 0;
  }

  private async drain(): Promise<void> {
    try {
      while (!this.closed && this.frames.length > 0) {
        const text = this.frames.shift()!;
        this.queuedChars -= text.length;
        try {
          await this.handle(text);
        } catch (error: unknown) {
          if (this.closed) continue;
          try {
            this.onError(error, text);
          } catch (reportError: unknown) {
            console.error("cetas-js: Board queue error handler failed", reportError);
          }
        }
      }
    } finally {
      this.running = false;
    }
  }
}
