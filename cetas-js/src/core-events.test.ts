import { describe, expect, test } from "bun:test";

import { parseCoreCustom } from "./core-events.ts";

const OP_START = {
  type: "custom",
  source: "posoco.operation",
  label: "operation_started",
  data: { operation_id: "agent_wakeup_w1", session: "s1", origin: "wakeup" },
};

const OP_SETTLE = {
  type: "custom",
  source: "posoco.operation",
  label: "operation_settled",
  data: {
    operation_id: "agent_wakeup_w1",
    session: "s1",
    origin: "wakeup",
    outcome: "completed",
  },
};

describe("parseCoreCustom", () => {
  test("parses operation started and settled with the frozen fields", () => {
    expect(parseCoreCustom(OP_START.source, OP_START.label, OP_START.data)).toEqual({
      kind: "operation",
      event: {
        phase: "started",
        operation_id: "agent_wakeup_w1",
        session: "s1",
        origin: "wakeup",
      },
    });
    expect(parseCoreCustom(OP_SETTLE.source, OP_SETTLE.label, OP_SETTLE.data)).toEqual({
      kind: "operation",
      event: {
        phase: "settled",
        operation_id: "agent_wakeup_w1",
        session: "s1",
        origin: "wakeup",
        outcome: "completed",
      },
    });
  });

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

  test("parses all seven wakeup states and the optional envelope", () => {
    for (const state of [
      "requested",
      "executing",
      "satisfied",
      "completed",
      "failed",
      "cancelled",
      "dropped",
    ]) {
      const parsed = parseCoreCustom("posoco.wakeup", `wakeup_${state}`, {
        ticket_id: "t1",
        session: "s1",
        tag: "build-watch",
        extension_id: "posoco_ext_subagent",
        ticket_enqueued_at: 42,
      });
      expect(parsed).toMatchObject({ kind: "wakeup", event: { state } });
    }
    const executing = parseCoreCustom("posoco.wakeup", "wakeup_executing", {
      ticket_id: "t1",
      session: "s1",
      tag: "build-watch",
      extension_id: "posoco_ext_subagent",
      ticket_enqueued_at: 42,
      operation_id: "agent_wakeup_w1",
      envelope: "[posoco-wakeup tag=build-watch] build failed",
    });
    expect(executing).toMatchObject({
      kind: "wakeup",
      event: {
        state: "executing",
        operation_id: "agent_wakeup_w1",
        envelope: "[posoco-wakeup tag=build-watch] build failed",
      },
    });
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

  test("parses background_outcome_ready for the four authoritative statuses", () => {
    for (const status of ["completed", "failed", "timed_out", "cancelled"]) {
      expect(
        parseCoreCustom("posoco.tasks", "background_outcome_ready", {
          task_id: "task_1",
          session: "s1",
          extension_id: "posoco_ext_subagent",
          label: "explore",
          status,
        }),
      ).toMatchObject({ kind: "task", event: { status } });
    }
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

  test("parses decision diagnostics without requiring the optional attributions", () => {
    expect(
      parseCoreCustom("posoco.decision", "decision_failed", {
        call_id: "d1",
        consumer: "posoco_ext_permission",
        provider: "auto_allow",
        purpose: "tool_gate",
        failure_mode: "fail_closed",
      }),
    ).toEqual({
      kind: "decision",
      event: {
        label: "failed",
        call_id: "d1",
        consumer: "posoco_ext_permission",
        provider: "auto_allow",
        purpose: "tool_gate",
        failure_mode: "fail_closed",
        scope: undefined,
        elapsed_ms: undefined,
        model: undefined,
      },
    });
    expect(
      parseCoreCustom("posoco.decision", "decision_completed", {}).kind,
    ).toBe("malformed");
    expect(parseCoreCustom("posoco.decision", "decision_started", { call_id: "d" }))
      .toMatchObject({ kind: "decision", event: { label: "started", call_id: "d" } });
  });

  test("foreign sources stay foreign; non-object data is malformed", () => {
    expect(parseCoreCustom("posoco.oauth", "progress", {}).kind).toBe("foreign");
    expect(parseCoreCustom("posoco_ext_subagent", "spawned", {}).kind).toBe("foreign");
    expect(
      parseCoreCustom("posoco.operation", "operation_started", "nope").kind,
    ).toBe("malformed");
  });
});
