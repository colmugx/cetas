/** A command retains exclusive occupancy through every awaited modal and mutation. */
export class CommandRunner {
  private active?: AbortController;
  constructor(private readonly start: (label: string) => void, private readonly finish: () => void) {}
  get busy(): boolean { return this.active !== undefined; }

  async run<T>(label: string, body: (signal: AbortSignal) => Promise<T>): Promise<T> {
    if (this.active !== undefined) throw new Error("command already running");
    const controller = new AbortController();
    this.active = controller;
    try {
      this.start(label);
      return await body(controller.signal);
    } finally {
      controller.abort();
      if (this.active === controller) {
        this.active = undefined;
        this.finish();
      }
    }
  }

  /** Shutdown cancels pending dialogs. An in-flight app mutation still needs to finish. */
  cancel(): void { this.active?.abort(); }
}
