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
export class CommandLock {
  private held = false;

  constructor(
    private readonly onAcquire: (label: string) => void,
    private readonly onRelease: () => void,
  ) {}

  get isHeld(): boolean {
    return this.held;
  }

  acquire(label: string): void {
    this.held = true;
    this.onAcquire(label);
  }

  release(): void {
    if (!this.held) return;
    this.held = false;
    this.onRelease();
  }
}
