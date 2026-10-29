import { describe, expect, test } from "bun:test";
import {
  BoardFrameQueue,
  BOARD_MAX_FRAME_CHARS,
  BOARD_MAX_QUEUED_FRAMES,
  BOARD_MAX_QUEUED_CHARS,
} from "./board-frame-queue.ts";

async function settle() {
  for (let i = 0; i < 6; i++) await Promise.resolve();
}

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => { resolve = done; });
  return { promise, resolve };
}

describe("Board bounded per-client frame queue", () => {
  test("serializes commands and releases pending frames after a close", async () => {
    const first = deferred();
    const started: string[] = [];
    const errors: unknown[] = [];
    const queue = new BoardFrameQueue(async (text) => {
      started.push(text);
      if (text === "first") await first.promise;
    }, (error) => errors.push(error));
    expect(queue.enqueue("first")).toBe(true);
    expect(queue.enqueue("second")).toBe(true);
    expect(queue.enqueue("third")).toBe(true);
    await settle();
    expect(started).toEqual(["first"]);
    queue.close();
    first.resolve();
    await settle();
    expect(started).toEqual(["first"]);
    expect(queue.enqueue("after-close")).toBe(false);
    expect(errors).toEqual([]);
  });

  test("holds at most the configured number of frames behind a blocked command", async () => {
    const release = deferred();
    const queue = new BoardFrameQueue(async (text) => {
      if (text === "busy") await release.promise;
    }, () => {});
    expect(queue.enqueue("busy")).toBe(true);
    for (let i = 0; i < BOARD_MAX_QUEUED_FRAMES; i++) {
      expect(queue.enqueue("queued-" + i)).toBe(true);
    }
    expect(queue.enqueue("overflow")).toBe(false);
    queue.close();
    release.resolve();
    await settle();
  });

  test("rejects oversized frames and enforces a total waiting-text budget", async () => {
    const release = deferred();
    const queue = new BoardFrameQueue(async (text) => {
      if (text === "busy") await release.promise;
    }, () => {});
    expect(queue.enqueue("x".repeat(BOARD_MAX_FRAME_CHARS + 1))).toBe(false);
    expect(queue.enqueue("busy")).toBe(true);
    const half = "x".repeat(Math.floor(BOARD_MAX_QUEUED_CHARS / 2));
    expect(queue.enqueue(half)).toBe(true);
    expect(queue.enqueue(half)).toBe(true);
    expect(queue.enqueue("extra")).toBe(false);
    queue.close();
    release.resolve();
    await settle();
  });

  test("reports a failed command and still executes the next queued frame", async () => {
    const commands: string[] = [];
    const errors: string[] = [];
    const queue = new BoardFrameQueue(async (text) => {
      commands.push(text);
      if (text === "bad") throw new Error("backend down");
    }, (error, text) => errors.push(text + ":" + String(error)));
    expect(queue.enqueue("bad")).toBe(true);
    expect(queue.enqueue("good")).toBe(true);
    await settle();
    expect(commands).toEqual(["bad", "good"]);
    expect(errors).toHaveLength(1);
    expect(errors[0]).toContain("bad:Error: backend down");
  });
});
