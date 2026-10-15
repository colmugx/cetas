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
import { parseWaitingReceipt, subagentRenderer } from "./subagent.ts";
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

  it("exports the renderer plus pure receipt helpers — no rows or ticker", async () => {
    const mod = await import("./subagent.ts");
    // `WaitingReceipt` is a type-only export and never appears at runtime.
    expect(Object.keys(mod).sort()).toEqual([
      "parseWaitingReceipt",
      "subagentRenderer",
    ]);
  });
});

describe("waiting_reply result card", () => {
  const structured = {
    status: "waiting_reply",
    question_id: "question-1",
    child_session: "sub-1",
    kind: "coder",
    question: "Which database should we use?",
    type: "select",
    options: ["postgres", "sqlite"],
  };
  const receiptContent =
    "status: waiting_reply\nsubagent asked a question and is waiting (NOT finished)\nchild_session: sub-1\nkind: coder\nquestion: Which database should we use?\ntype: select\noptions: postgres | sqlite\nanswer with answer_question(question_id=\"question-1\"); after answering, the child continues and its final result arrives as a follow-up turn";

  function renderResult(
    payload: { content: string; isError: boolean; structured?: unknown },
    ctxOverrides: Partial<ToolRenderContext> = {},
    expanded = false,
  ): string {
    return subagentRenderer
      .renderResult!(payload, { expanded, isPartial: false }, makeCtx(ctxOverrides))
      .render(80)
      .join("\n");
  }

  function storeWithNick(): { store: SubagentActivityStore; nick: string } {
    const store = new SubagentActivityStore();
    store.apply(childEvent("sub-1", "call_1", { type: "turn_started" }));
    return { store, nick: store.get("sub-1")!.display_name };
  }

  it("renders the question card from the structured receipt", () => {
    const { store, nick } = storeWithNick();
    const text = renderResult(
      { content: receiptContent, isError: false, structured },
      { subagentActivity: store },
    );
    expect(text).toContain(`${nick} asks`);
    expect(text).toContain("question-1");
    expect(text).toContain('"Which database should we use?"');
    expect(text).toContain("[select]");
    expect(text).toContain("「postgres」");
    expect(text).toContain(
      'answer with answer_question(question_id="question-1")',
    );
  });

  it("expanded adds the child session and kind", () => {
    const text = renderResult(
      { content: receiptContent, isError: false, structured },
      {},
      true,
    );
    expect(text).toContain("child_session: sub-1");
    expect(text).toContain("kind: coder");
  });

  it("rebuilds the card from content alone (replay path)", () => {
    const text = renderResult({ content: receiptContent, isError: false });
    expect(text).toContain("coder asks");
    expect(text).toContain('"Which database should we use?"');
    expect(text).toContain("「sqlite」");
    expect(text).toContain(
      'answer with answer_question(question_id="question-1")',
    );
  });

  it("non-waiting and error results never render the card", () => {
    const done = renderResult({
      content: "task done",
      isError: false,
      structured: { status: "completed" },
    });
    expect(done).not.toContain("asks");
    const failed = renderResult({
      content: receiptContent,
      isError: true,
    });
    expect(failed).not.toContain("asks");
  });

  it("parseWaitingReceipt rejects non-waiting content", () => {
    expect(parseWaitingReceipt("ok")).toBeUndefined();
    expect(
      parseWaitingReceipt("status: completed\nquestion: ignored"),
    ).toBeUndefined();
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
