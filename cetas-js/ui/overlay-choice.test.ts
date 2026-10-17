import { describe, expect, test } from "bun:test";
import { OverlayChoice } from "./overlay-choice.ts";

describe("OverlayChoice", () => {
  test("selection settles once, even if hide follows", async () => {
    const choice = new OverlayChoice<string>();
    const pending = choice.wait(() => {}, () => {});
    choice.select("model-a");
    choice.cancel();
    expect(await pending).toBe("model-a");
    expect(choice.isPending).toBe(false);
  });

  test("programmatic hide is cancellation, never a stuck promise", async () => {
    const choice = new OverlayChoice<string>();
    const pending = choice.wait(() => {}, () => {});
    choice.cancel();
    expect(await pending).toBeUndefined();
  });

  test("abort calls hide and resolves cancellation", async () => {
    const controller = new AbortController();
    let hidden = 0;
    const choice = new OverlayChoice<string>();
    const pending = choice.wait(() => {}, () => { hidden += 1; choice.cancel(); }, controller.signal);
    controller.abort();
    expect(await pending).toBeUndefined();
    expect(hidden).toBe(1);
  });

  test("already aborted never opens", async () => {
    const controller = new AbortController();
    controller.abort();
    const choice = new OverlayChoice<string>();
    expect(await choice.wait(() => { throw new Error("should not open"); }, () => {}, controller.signal)).toBeUndefined();
  });

  test("opening failure rejects and leaves no dangling selection", async () => {
    const choice = new OverlayChoice<string>();
    await expect(choice.wait(() => { throw new Error("broken TUI"); }, () => {})).rejects.toThrow("broken TUI");
    expect(choice.isPending).toBe(false);
    const next = choice.wait(() => {}, () => {});
    choice.cancel();
    expect(await next).toBeUndefined();
  });
});
