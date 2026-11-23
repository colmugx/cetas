import { describe, expect, test } from "bun:test";

import { parseCoreCustom } from "./core-events.ts";

describe("parseCoreCustom", () => {
  test("operation rejects unknown origins and a settled without its outcome", () => {
    expect(
      parseCoreCustom("posoco.operation", "operation_started", {
        operation_id: "op",
        session: "s",
        origin: "cron",
      }).kind,
    ).toBe("malformed");
    const settled = parseCoreCustom("posoco.operation", "operation_settled", {
      operation_id: "op",
      session: "s",
      origin: "turn",
    });
    expect(settled.kind).toBe("malformed");
    if (settled.kind === "malformed") {
      expect(settled.reason).toContain("outcome");
    }
  });

  test("wakeup rejects an unknown label and missing ticket identity", () => {
    expect(
      parseCoreCustom("posoco.wakeup", "wakeup_retried", {
        ticket_id: "t",
        session: "s",
        tag: "g",
        extension_id: "e",
        ticket_enqueued_at: 1,
      }).kind,
    ).toBe("malformed");
    expect(
      parseCoreCustom("posoco.wakeup", "wakeup_requested", {
        session: "s",
        tag: "g",
        extension_id: "e",
        ticket_enqueued_at: 1,
      }).kind,
    ).toBe("malformed");
  });

  test("rejects a non-terminal background outcome", () => {
    expect(
      parseCoreCustom("posoco.tasks", "background_outcome_ready", {
        task_id: "task_1",
        session: "s1",
        extension_id: "posoco_ext_subagent",
        label: "explore",
        status: "running",
      }).kind,
    ).toBe("malformed");
  });

  test("rejects a decision diagnostic without a call id", () => {
    expect(
      parseCoreCustom("posoco.decision", "decision_completed", {}).kind,
    ).toBe("malformed");
  });

  test("foreign sources stay foreign; non-object data is malformed", () => {
    expect(parseCoreCustom("posoco.oauth", "progress", {}).kind).toBe("foreign");
    expect(parseCoreCustom("posoco_ext_subagent", "spawned", {}).kind).toBe("foreign");
    expect(
      parseCoreCustom("posoco.operation", "operation_started", "nope").kind,
    ).toBe("malformed");
  });
});
