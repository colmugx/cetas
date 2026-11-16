import { describe, expect, test } from "bun:test";
import { SessionEventCursor } from "../cetas-web/web/src/lib/event-cursor";

describe("SessionEventCursor", () => {
  test("snapshot establishes the high-water baseline", () => {
    const cursor = new SessionEventCursor();
    expect(cursor.accept({
      type: "session.snapshot", session_id: "s1", runtime_epoch: "e1",
      cursor: 8, high_water_cursor: 8,
    })).toEqual({ kind: "snapshot", cursor: 8, epoch: "e1" });
    expect(cursor.cursor("s1")).toBe(8);
  });

  test("contiguous broadcasts advance independently per session", () => {
    const cursor = new SessionEventCursor();
    cursor.accept({ type: "session.snapshot", session_id: "a", runtime_epoch: "e1", high_water_cursor: 2 });
    cursor.accept({ type: "session.snapshot", session_id: "b", runtime_epoch: "e1", high_water_cursor: 7 });
    expect(cursor.accept({ type: "turn.accepted", session_id: "a", runtime_epoch: "e1", cursor: 3, cursor_advance: true })).toEqual({ kind: "event", cursor: 3 });
    expect(cursor.accept({ type: "turn.accepted", session_id: "b", runtime_epoch: "e1", cursor: 8, cursor_advance: true })).toEqual({ kind: "event", cursor: 8 });
  });

  test("unicast frames do not advance or create false gaps", () => {
    const cursor = new SessionEventCursor();
    cursor.accept({ type: "session.snapshot", session_id: "a", runtime_epoch: "e1", high_water_cursor: 4 });
    expect(cursor.accept({ type: "connection.ready", session_id: "a", runtime_epoch: "e1", cursor: 4, cursor_advance: false })).toEqual({ kind: "unsequenced" });
    expect(cursor.cursor("a")).toBe(4);
  });

  test("duplicate and out-of-order broadcasts are distinguished", () => {
    const cursor = new SessionEventCursor();
    cursor.accept({ type: "session.snapshot", session_id: "a", runtime_epoch: "e1", high_water_cursor: 4 });
    const event = { type: "turn.started", session_id: "a", runtime_epoch: "e1", cursor: 5, cursor_advance: true };
    expect(cursor.accept(event)).toEqual({ kind: "event", cursor: 5 });
    expect(cursor.accept(event)).toEqual({ kind: "duplicate" });
    expect(cursor.accept({ ...event, cursor: 7 })).toEqual({ kind: "gap", expected: 6, received: 7 });
    expect(cursor.cursor("a")).toBe(5);
  });

  test("runtime epoch changes require a fresh snapshot", () => {
    const cursor = new SessionEventCursor();
    cursor.accept({ type: "session.snapshot", session_id: "a", runtime_epoch: "e1", high_water_cursor: 9 });
    expect(cursor.accept({ type: "turn.started", session_id: "a", runtime_epoch: "e2", cursor: 1, cursor_advance: true })).toEqual({ kind: "epoch_changed", previous: "e1", received: "e2" });
    expect(cursor.accept({ type: "session.snapshot", session_id: "a", runtime_epoch: "e2", high_water_cursor: 1 })).toEqual({ kind: "snapshot", cursor: 1, epoch: "e2" });
  });

  test("a runtime epoch change clears every Session cursor", () => {
    const cursor = new SessionEventCursor();
    cursor.accept({ type: "session.snapshot", session_id: "a", runtime_epoch: "e1", high_water_cursor: 9 });
    cursor.accept({ type: "session.snapshot", session_id: "b", runtime_epoch: "e1", high_water_cursor: 4 });
    expect(cursor.accept({ type: "session.snapshot", session_id: "a", runtime_epoch: "e2", high_water_cursor: 1 })).toEqual({ kind: "snapshot", cursor: 1, epoch: "e2" });
    expect(cursor.cursor("b")).toBe(0);
    expect(cursor.accept({ type: "turn.started", session_id: "b", runtime_epoch: "e2", cursor: 1, cursor_advance: true })).toEqual({ kind: "event", cursor: 1 });
  });

  test("an older snapshot cannot rewind a Session cursor", () => {
    const cursor = new SessionEventCursor();
    cursor.accept({ type: "session.snapshot", session_id: "a", runtime_epoch: "e1", high_water_cursor: 4 });
    cursor.accept({ type: "turn.started", session_id: "a", runtime_epoch: "e1", cursor: 5, cursor_advance: true });
    expect(cursor.accept({ type: "session.snapshot", session_id: "a", runtime_epoch: "e1", high_water_cursor: 3 })).toEqual({ kind: "duplicate" });
    expect(cursor.cursor("a")).toBe(5);
  });
});
