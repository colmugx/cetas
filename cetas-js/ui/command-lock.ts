/**
 * Framework-free command-busy gate for terminal command flows.
 *
 * acquire always re-arms: runLogin legitimately re-acquires while the
 * provider picker already holds the lock, and the re-arm refreshes the
 * armed state exactly like the flag re-sets it replaced. release is
 * idempotent — only the first release after an acquire fires onRelease —
 * so nested acquires make a finally-release safe and double releases
 * (error path + close callback) are harmless.
 */
/** One invocation's authority to release a lock. Old callbacks cannot release a newer owner. */
export interface CommandLease {
  release(): void;
}

export class CommandLock {
  private held = false;
  private epoch = 0;

  constructor(
    private readonly onAcquire: (label: string) => void,
    private readonly onRelease: () => void,
  ) {}

  get isHeld(): boolean {
    return this.held;
  }

  acquire(label: string): void {
    this.epoch += 1;
    this.held = true;
    this.onAcquire(label);
  }

  /** Strict acquisition for a single command; use its lease in async callbacks. */
  lease(label: string): CommandLease {
    if (this.held) throw new Error("a command already owns the lock");
    this.acquire(label);
    const owner = this.epoch;
    return {
      release: () => {
        if (this.held && this.epoch === owner) this.release();
      },
    };
  }

  release(): void {
    if (!this.held) return;
    this.held = false;
    this.onRelease();
  }
}
