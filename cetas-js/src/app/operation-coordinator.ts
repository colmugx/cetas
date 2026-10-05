import type {
  OperationKind,
  OperationPhase,
  OperationSnapshot,
} from "./types.ts";

export interface OperationLease {
  readonly id: number;
  readonly kind: OperationKind;
  readonly settled: Promise<void>;
}

export interface CompactRequestLease {
  readonly controller: AbortController;
  readonly settled: Promise<void>;
}

interface ActiveOperation {
  id: number;
  kind: OperationKind;
  phase: Exclude<OperationPhase, "idle">;
  interruptible: boolean;
  abort?: AbortController;
  session?: string;
  /** Core-projected lease: admitted by the Agent without a host promise. */
  projected: boolean;
  followUpsQueued: number;
  settled: Promise<void>;
  resolveSettled: () => void;
}

interface CompactRequest {
  controller: AbortController;
  settled: Promise<void>;
  resolveSettled: () => void;
}

/**
 * Single authority for Agent-operation ownership inside cetas-js.
 *
 * Application readiness is still projected as AppState, but turn/recovery/
 * compact ownership, cancellation phase, finalize barriers, and compact's
 * next-operation reservation live here. Renderers may inspect snapshots; they
 * never mutate or mirror this state.
 */
export class OperationCoordinator {
  private nextId = 1;
  private active?: ActiveOperation;
  private compactRequest?: CompactRequest;
  private shutdownRequested = false;

  get busy(): boolean {
    return this.active !== undefined;
  }

  get activeKind(): OperationKind | undefined {
    return this.active?.kind;
  }

  get activePhase(): Exclude<OperationPhase, "idle"> | undefined {
    return this.active?.phase;
  }

  get activeAbort(): AbortController | undefined {
    return this.active?.abort;
  }

  get activeSettled(): Promise<void> | undefined {
    return this.active?.settled;
  }

  get recoveryFollowUpsQueued(): number {
    return this.active?.kind === "recovery" ? this.active.followUpsQueued : 0;
  }

  get compactPending(): boolean {
    return this.compactRequest !== undefined || this.active?.kind === "compact";
  }

  get shuttingDown(): boolean {
    return this.shutdownRequested;
  }

  snapshot(): OperationSnapshot {
    const active = this.active;
    return {
      busy: active !== undefined,
      phase: active?.phase ?? "idle",
      ...(active === undefined
        ? {}
        : {
            id: active.id,
            kind: active.kind,
            ...(active.session === undefined ? {} : { session: active.session }),
          }),
      interruptible: active?.interruptible ?? false,
      followUpsQueued:
        active?.kind === "recovery" ? active.followUpsQueued : 0,
      compactPending: this.compactPending,
      shuttingDown: this.shutdownRequested,
    };
  }

  get activeLease(): OperationLease | undefined {
    const active = this.active;
    if (active === undefined) return undefined;
    return { id: active.id, kind: active.kind, settled: active.settled };
  }

  begin(
    kind: OperationKind,
    options: {
      abort?: AbortController;
      interruptible?: boolean;
      session?: string;
      projected?: boolean;
    } = {},
  ): OperationLease | undefined {
    if (this.shutdownRequested || this.active !== undefined) return undefined;
    // A compact request reserves the next Agent operation while it interrupts
    // and drains the previous owner. No fresh host turn may jump ahead of it
    // (the compact itself claims the reservation). A projected core
    // operation bypasses the reservation: the Agent already admitted it, so
    // hiding it behind a host reservation would mask the real busy truth.
    if (
      this.compactRequest !== undefined &&
      kind !== "compact" &&
      options.projected !== true
    ) {
      return undefined;
    }

    let resolveSettled!: () => void;
    const settled = new Promise<void>((resolve) => {
      resolveSettled = resolve;
    });
    const active: ActiveOperation = {
      id: this.nextId++,
      kind,
      phase: "running",
      interruptible: options.interruptible ?? options.abort !== undefined,
      ...(options.abort === undefined ? {} : { abort: options.abort }),
      ...(options.session === undefined ? {} : { session: options.session }),
      projected: options.projected ?? false,
      followUpsQueued: 0,
      settled,
      resolveSettled,
    };
    this.active = active;
    return { id: active.id, kind, settled };
  }

  /**
   * Transition the owning operation into cancellation exactly once.
   * Returns true only for the first running -> cancelling transition so
   * callers can keep mailbox abort and hard-abort watchdog side effects
   * idempotent under repeated ESC / shutdown requests.
   */
  requestCancellation(lease: OperationLease): boolean {
    if (!this.owns(lease) || this.active === undefined) return false;
    if (this.active.phase !== "running") return false;
    this.active.phase = "cancelling";
    return true;
  }

  markFinalizing(lease: OperationLease): void {
    if (this.owns(lease) && this.active !== undefined) {
      this.active.phase = "finalizing";
    }
  }

  finish(lease: OperationLease): void {
    const active = this.active;
    if (active === undefined || active.id !== lease.id) return;
    this.active = undefined;
    active.resolveSettled();
  }

  incrementRecoveryFollowUp(): void {
    if (this.active?.kind === "recovery") this.active.followUpsQueued += 1;
  }

  consumeRecoveryFollowUpStart(): void {
    if (
      this.active?.kind === "recovery" &&
      this.active.followUpsQueued > 0
    ) {
      this.active.followUpsQueued -= 1;
    }
  }

  clearRecoveryFollowUps(): void {
    if (this.active?.kind === "recovery") this.active.followUpsQueued = 0;
  }

  async waitForActiveToSettle(): Promise<void> {
    const settled = this.active?.settled;
    if (settled !== undefined) await settled;
  }

  async waitUntilAvailable(): Promise<void> {
    while (true) {
      const active = this.active?.settled;
      if (active !== undefined) {
        await active;
        continue;
      }
      const compact = this.compactRequest?.settled;
      if (compact !== undefined) {
        await compact;
        continue;
      }
      return;
    }
  }

  beginCompactRequest(): CompactRequestLease | undefined {
    if (this.shutdownRequested || this.compactRequest !== undefined) {
      return undefined;
    }
    let resolveSettled!: () => void;
    const settled = new Promise<void>((resolve) => {
      resolveSettled = resolve;
    });
    const request: CompactRequest = {
      controller: new AbortController(),
      settled,
      resolveSettled,
    };
    this.compactRequest = request;
    return { controller: request.controller, settled };
  }

  cancelCompactRequest(): boolean {
    const request = this.compactRequest;
    if (request === undefined) return false;
    if (!request.controller.signal.aborted) request.controller.abort();
    return true;
  }

  endCompactRequest(lease: CompactRequestLease): void {
    const request = this.compactRequest;
    if (
      request === undefined ||
      request.controller !== lease.controller
    ) return;
    this.compactRequest = undefined;
    request.resolveSettled();
  }

  markShuttingDown(): void {
    this.shutdownRequested = true;
    this.cancelCompactRequest();
  }

  private owns(lease: OperationLease): boolean {
    return this.active?.id === lease.id;
  }
}
