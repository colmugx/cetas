import { describe, expect, test } from "bun:test";
import { CommandLock } from "./command-lock.ts";

describe("CommandLock", () => {
  test("acquire arms via onAcquire and reports held", () => {
    const armed: string[] = [];
    const lock = new CommandLock((label) => armed.push(label), () => {});
    expect(lock.isHeld).toBe(false);
    lock.acquire("loading model catalog");
    expect(armed).toEqual(["loading model catalog"]);
    expect(lock.isHeld).toBe(true);
  });

  test("release is idempotent — onRelease fires exactly once", () => {
    let releases = 0;
    const lock = new CommandLock(() => {}, () => {
      releases += 1;
    });
    lock.acquire("cmd");
    lock.release();
    lock.release();
    expect(releases).toBe(1);
    expect(lock.isHeld).toBe(false);
  });

  test("double-acquire is tolerated; the finally-release fully releases", () => {
    const armed: string[] = [];
    let releases = 0;
    const lock = new CommandLock((label) => armed.push(label), () => {
      releases += 1;
    });
    lock.acquire("provider picker");
    lock.acquire("authenticating github");
    expect(armed).toEqual(["provider picker", "authenticating github"]);
    expect(lock.isHeld).toBe(true);
    lock.release();
    expect(releases).toBe(1);
    expect(lock.isHeld).toBe(false);
  });

  test("release before any acquire is a no-op", () => {
    let releases = 0;
    const lock = new CommandLock(() => {}, () => {
      releases += 1;
    });
    lock.release();
    expect(releases).toBe(0);
    expect(lock.isHeld).toBe(false);
  });

  test("isHeld transitions across acquire/release cycles", () => {
    const lock = new CommandLock(() => {}, () => {});
    expect(lock.isHeld).toBe(false);
    lock.acquire("a");
    expect(lock.isHeld).toBe(true);
    lock.release();
    expect(lock.isHeld).toBe(false);
    lock.acquire("b");
    expect(lock.isHeld).toBe(true);
    lock.release();
    expect(lock.isHeld).toBe(false);
  });
});


describe("CommandLease ownership", () => {
  test("a lease releases its command exactly once", () => {
    let released = 0;
    const lock = new CommandLock(() => {}, () => { released += 1; });
    const lease = lock.lease("quota");
    expect(lock.isHeld).toBe(true);
    lease.release();
    lease.release();
    expect(lock.isHeld).toBe(false);
    expect(released).toBe(1);
  });

  test("a stale asynchronous callback cannot unlock a later command", () => {
    let released = 0;
    const lock = new CommandLock(() => {}, () => { released += 1; });
    const first = lock.lease("model");
    first.release();
    const second = lock.lease("update");
    first.release();
    expect(lock.isHeld).toBe(true);
    expect(released).toBe(1);
    second.release();
    expect(released).toBe(2);
  });

  test("strict lease acquisition rejects accidental overlapping commands", () => {
    const lock = new CommandLock(() => {}, () => {});
    const lease = lock.lease("first");
    expect(() => lock.lease("second")).toThrow("already owns");
    lease.release();
  });
});
