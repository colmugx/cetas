/**
 * subagent.test.ts — the `agent` renderer and its ToolRow live contract.
 *
 * The renderer is pure: child-run snapshots come from the store the host
 * injected via ToolRowOptions → ctx.subagentActivity, keyed on the row's
 * FINAL call id. No module-level row registry, no ticker — refresh
 * eligibility lives on ToolRow.refreshLive() (finished rows refuse), and
 * streaming adoption must re-key the row to the real call id.
 */

import { describe, expect, it } from "bun:test";
import { Text } from "@earendil-works/pi-tui";
import { ToolRow } from "../transcript/components.ts";
import { parseCetasEvent } from "../events.ts";
import { SubagentActivityStore } from "../controllers/subagent-activity.ts";
import { subagentRenderer } from "./subagent.ts";
import type { ToolRenderContext } from "./registry.ts";

/** Build one parsed `subagent_event` from a raw child turn event. */
function childEvent(
  childSession: string,
  parentCall: string,
  inner: Record<string, unknown>,
) {
  return parseCetasEvent({
    type: "subagent_event",
    child_session: childSession,
    kind: "coder",
    parent_call: parentCall,
    ev: inner,
  })!;
}

/** Full ToolRenderContext fixture — callers override what they care about. */
function makeCtx(overrides: Partial<ToolRenderContext> = {}): ToolRenderContext {
  return {
    toolCallId: "call_1",
    toolName: "agent",
    toolLabel: "agent",
    args: {},
    cwd: "/tmp/fake",
    state: {},
    executionStarted: true,
    argsComplete: true,
    isPartial: false,
    isError: false,
    expanded: false,
    invalidate: () => {},
    ...overrides,
  };
}

/** A store with one running child (1 step, currently in `grep`). */
function storeWithRun(parentCall: string): SubagentActivityStore {
  const store = new SubagentActivityStore();
  store.apply(childEvent("sub-1", parentCall, { type: "turn_started" }));
  store.apply(
    childEvent("sub-1", parentCall, {
      type: "tool_call_started",
      tool_call_id: "t1",
      tool_name: "grep",
      args: { pattern: "todo" },
    }),
  );
  return store;
}

describe("subagentRenderer", () => {
  it("renders live child data from the injected store, keyed on ctx.toolCallId", () => {
    const store = storeWithRun("call_1");
    const text = subagentRenderer
      .renderCall!(makeCtx({ subagentActivity: store }))
      .render(80)
      .join("\n");
    expect(text).toContain("agent");
    expect(text).toContain("coder");
    expect(text).toContain("step 1");
    expect(text).toContain("grep");
  });

  it("renders the bare call line when no store is injected (plain harness)", () => {
    const text = subagentRenderer.renderCall!(makeCtx()).render(80).join("\n");
    expect(text).toContain("agent");
    expect(text).not.toContain("step");
  });

  it("shows the bounded step history only when expanded", () => {
    const store = storeWithRun("call_1");
    const collapsed = subagentRenderer
      .renderCall!(makeCtx({ subagentActivity: store }))
      .render(80)
      .join("\n");
    expect(collapsed).not.toContain("▸ grep");
    const expanded = subagentRenderer
      .renderCall!(makeCtx({ subagentActivity: store, expanded: true }))
      .render(80)
      .join("\n");
    expect(expanded).toContain("▸ grep");
  });

  it("renderResult always returns a Component (never undefined)", () => {
    const result = subagentRenderer.renderResult!(
      { content: "ok", isError: false },
      { expanded: false, isPartial: false },
      makeCtx(),
    );
    expect(result).toBeDefined();
    expect(result.render(80).join("\n")).toContain("agent");
  });

  it("exports only the renderer — no module-level rows or ticker", async () => {
    const mod = await import("./subagent.ts");
    expect(Object.keys(mod).sort()).toEqual(["subagentRenderer"]);
  });
});

describe("agent ToolRow live contract", () => {
  it("refreshLive() ticks a pending row and refuses a finished one", () => {
    const store = storeWithRun("call_1");
    const row = new ToolRow(
      "agent",
      "call_1",
      {},
      "/tmp/fake",
      () => {},
      "agent",
      false,
      { subagentActivity: store },
    );
    expect(row.render(80).join("\n")).toContain("step 1");

    store.apply(childEvent("sub-1", "call_1", { type: "turn_started" })); // steps → 2
    expect(row.render(80).join("\n")).toContain("step 1"); // stale until refresh
    expect(row.refreshLive()).toBe(true);
    expect(row.render(80).join("\n")).toContain("step 2");

    row.setResult("done", false);
    expect(row.refreshLive()).toBe(false); // finished rows never rebuild
    expect(row.render(80).join("\n")).toContain("done");
  });

  it("streaming adoption re-keys the row so the renderer sees the final call id", () => {
    const store = storeWithRun("call_9");
    const row = new ToolRow(
      "agent",
      "#0",
      {},
      "/tmp/fake",
      () => {},
      "agent",
      false,
      { streaming: true, subagentActivity: store },
    );
    // The temp `#0` key resolves nothing while the store keys on `call_9`.
    expect(row.render(80).join("\n")).not.toContain("step 1");
    row.setCallId("call_9");
    expect(row.render(80).join("\n")).toContain("step 1");
  });
});
