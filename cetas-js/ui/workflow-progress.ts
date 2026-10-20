type RecordValue = Record<string, unknown>;
function record(value: unknown): RecordValue | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as RecordValue : undefined;
}

/** Presentation polling only: the injected read uses the existing status lane.
 * Never admits, retries or cancels execution; closing this display stops reads. */
export class WorkflowProgress {
  private timer?: ReturnType<typeof setTimeout>;
  private generation = 0;
  private reading = false;
  private wanted = false;
  private closed = false;
  private signature?: string;

  constructor(
    private readonly read: () => Promise<unknown>,
    private readonly render: (view: unknown) => void,
    private readonly failed: () => void,
    private readonly interval = 1000,
  ) {}

  observe(value: unknown): void {
    if (this.closed) return;
    const view = record(value);
    if (!view || !record(view.board)) return;
    const workflow = record(view.workflow);
    const executions = Array.isArray(view.executions) ? view.executions : [];
    const signature = JSON.stringify([
      workflow?.phase, workflow?.pending_proposal, workflow?.expansion_phase,
      workflow?.settled_executions, workflow?.blocked, view.executions,
      view.operation_active, view.unresolved, view.mutation_uncertain, view.stopped, view.paused,
    ]);
    this.signature = signature;
    if (view.unresolved === true || view.mutation_uncertain === true) {
      this.stop();
      return;
    }
    const active = executions.some(e => {
      const phase = record(e)?.phase;
      return typeof phase === "string" && phase !== "Settled";
    });
    if (active || view.operation_active === true) this.watch();
    else this.stop();
  }

  watch(): void {
    this.wanted = true;
    this.arm();
  }

  private arm(): void {
    if (this.closed || !this.wanted || this.timer !== undefined || this.reading) return;
    const generation = this.generation;
    this.timer = setTimeout(() => {
      this.timer = undefined;
      void this.refresh(generation);
    }, this.interval);
    this.timer.unref?.();
  }

  private async refresh(generation: number): Promise<void> {
    if (this.closed || this.reading || generation !== this.generation) return;
    this.reading = true;
    try {
      const value = await this.read();
      if (this.closed || generation !== this.generation) return;
      if (!record(record(value)?.board)) throw new Error("invalid workflow status");
      const before = this.signature;
      this.observe(value);
      if (this.signature !== before) this.render(value);
    } catch {
      if (!this.closed && generation === this.generation) {
        this.stop();
        this.failed();
      }
    } finally {
      this.reading = false;
      // A newer observation can request polling while an older read is in
      // flight. Discard the old result but do not lose the newer request.
      this.arm();
    }
  }

  private stop(): void {
    this.wanted = false;
    this.generation++;
    if (this.timer !== undefined) clearTimeout(this.timer);
    this.timer = undefined;
  }

  close(): void {
    this.closed = true;
    this.stop();
  }
}
