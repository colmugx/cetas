import { describe, expect, test } from "bun:test";
import { OperationCoordinator } from "./operation-coordinator.ts";

describe("OperationCoordinator", () => {
  test("one lease owns Agent execution and phase transitions until finalize", async () => {
    const coordinator = new OperationCoordinator();
    const abort = new AbortController();
    const turn = coordinator.begin("turn", { abort, interruptible: true });
    expect(turn).toBeDefined();
    if (turn === undefined) throw new Error("expected turn lease");

    expect(coordinator.snapshot()).toMatchObject({
      busy: true,
      kind: "turn",
      phase: "running",
      interruptible: true,
    });
    expect(coordinator.begin("recovery")).toBeUndefined();

    expect(coordinator.requestCancellation(turn)).toBe(true);
    expect(coordinator.snapshot().phase).toBe("cancelling");
    coordinator.markFinalizing(turn);
    expect(coordinator.snapshot().phase).toBe("finalizing");

    let settled = false;
    turn.settled.then(() => {
      settled = true;
    });
    coordinator.finish(turn);
    await turn.settled;
    expect(settled).toBe(true);
    expect(coordinator.snapshot()).toMatchObject({
      busy: false,
      phase: "idle",
    });
  });

  test("compact request reserves the next Agent operation across finalize", async () => {
    const coordinator = new OperationCoordinator();
    const turn = coordinator.begin("turn", { interruptible: true });
    expect(turn).toBeDefined();
    if (turn === undefined) throw new Error("expected turn lease");

    const compact = coordinator.beginCompactRequest();
    expect(compact).toBeDefined();
    if (compact === undefined) throw new Error("expected compact reservation");
    expect(coordinator.snapshot().compactPending).toBe(true);
    expect(coordinator.begin("recovery")).toBeUndefined();

    coordinator.finish(turn);
    expect(coordinator.begin("turn")).toBeUndefined();
    const compactLease = coordinator.begin("compact", {
      abort: compact.controller,
      interruptible: true,
    });
    expect(compactLease).toBeDefined();
    if (compactLease === undefined) throw new Error("expected compact lease");

    coordinator.finish(compactLease);
    coordinator.endCompactRequest(compact);
    await compact.settled;
    expect(coordinator.snapshot()).toMatchObject({
      busy: false,
      phase: "idle",
      compactPending: false,
    });
  });

  test("shutdown cancels a pending compact reservation and rejects new owners", () => {
    const coordinator = new OperationCoordinator();
    const compact = coordinator.beginCompactRequest();
    expect(compact).toBeDefined();
    if (compact === undefined) throw new Error("expected compact reservation");

    coordinator.markShuttingDown();
    expect(compact.controller.signal.aborted).toBe(true);
    expect(coordinator.begin("turn")).toBeUndefined();
    expect(coordinator.snapshot().shuttingDown).toBe(true);
  });
  test("cancellation is a single state transition", () => {
    const coordinator = new OperationCoordinator();
    const turn = coordinator.begin("turn", { interruptible: true });
    expect(turn).toBeDefined();
    if (turn === undefined) throw new Error("expected turn lease");

    expect(coordinator.requestCancellation(turn)).toBe(true);
    expect(coordinator.snapshot().phase).toBe("cancelling");
    expect(coordinator.requestCancellation(turn)).toBe(false);

    coordinator.markFinalizing(turn);
    expect(coordinator.requestCancellation(turn)).toBe(false);
    coordinator.finish(turn);
  });

  test("a projected core operation bypasses the compact reservation but not shutdown", () => {
    const coordinator = new OperationCoordinator();
    const reservation = coordinator.beginCompactRequest();
    expect(reservation).toBeDefined();

    const wakeup = coordinator.begin("wakeup", {
      projected: true,
      session: "session-1",
    });
    expect(wakeup).toBeDefined();
    expect(coordinator.snapshot()).toMatchObject({
      busy: true,
      kind: "wakeup",
      session: "session-1",
    });
    // Host-initiated operations still queue behind the reservation.
    expect(coordinator.begin("turn", { session: "session-1" })).toBeUndefined();

    coordinator.markShuttingDown();
    expect(
      coordinator.begin("wakeup", { projected: true, session: "session-1" }),
    ).toBeUndefined();
  });
});
