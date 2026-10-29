import { describe, expect, test } from "bun:test";
import { scheduleSingleFlightPoll } from "./board-polling.ts";

function manualClock() {
  let tick: (() => void) | undefined;
  let delay = -1;
  let unrefs = 0;
  const handle = {
    unref: () => { unrefs++; },
  } as unknown as ReturnType<typeof setInterval>;
  const schedule = (callback: () => void, ms: number) => {
    tick = callback;
    delay = ms;
    return handle;
  };
  return {
    schedule,
    tick: () => {
      if (tick === undefined) throw new Error("poller was not scheduled");
      tick();
    },
    delay: () => delay,
    unrefs: () => unrefs,
    handle,
  };
}

describe("Board single-flight polling", () => {
  test("unrefs the timer and never overlaps slow backend calls", async () => {
    const clock = manualClock();
    let settleFirst!: () => void;
    const first = new Promise<void>((resolve) => { settleFirst = resolve; });
    let calls = 0;
    const handle = scheduleSingleFlightPoll(1500, async () => {
      calls++;
      if (calls === 1) await first;
    }, clock.schedule);
    expect(handle).toBe(clock.handle);
    expect(clock.delay()).toBe(1500);
    expect(clock.unrefs()).toBe(1);

    clock.tick();
    await Bun.sleep(0);
    expect(calls).toBe(1);
    clock.tick();
    clock.tick();
    await Bun.sleep(0);
    expect(calls).toBe(1);

    settleFirst();
    await Bun.sleep(0);
    clock.tick();
    await Bun.sleep(0);
    expect(calls).toBe(2);
  });

  test("rejections release the gate for the next tick", async () => {
    const clock = manualClock();
    let calls = 0;
    scheduleSingleFlightPoll(1000, async () => {
      if (++calls === 1) throw new Error("offline");
    }, clock.schedule);
    clock.tick();
    await Bun.sleep(0);
    clock.tick();
    await Bun.sleep(0);
    expect(calls).toBe(2);
  });
});
