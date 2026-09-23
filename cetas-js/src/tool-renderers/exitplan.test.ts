/**
 * exitplan.test.ts — the `exit_plan_mode` renderer's two faces.
 *
 *   - call view: `● plan <name>` + the FULL plan as markdown (no preview
 *     cap — the user must read what they approve);
 *   - result view: outcome line + saved plan-file path, body not repeated.
 */

import { describe, expect, test } from "bun:test";
// Registration side effects so pickToolRenderer("exit_plan_mode") hits the hook.
import "./index.ts";
import { pickToolRenderer, type ToolRenderContext, type ToolRenderResultPayload } from "./registry.ts";
import { exitPlanRenderer } from "./exitplan.ts";

const ANSI = /\x1b\[[0-9;]*m/g;

function strip(s: string): string {
  return s.replace(ANSI, "");
}

function makeCtx(args: unknown): ToolRenderContext {
  return {
    toolCallId: "tc_plan",
    toolName: "exit_plan_mode",
    toolLabel: "exit_plan_mode",
    args,
    cwd: "/tmp",
    state: {},
    executionStarted: true,
    argsComplete: true,
    isPartial: false,
    isError: false,
    invalidate: () => {},
  };
}

function renderToString(component: { render(width: number): string[] }): string {
  return component.render(80).map((l) => strip(l).trim()).join("\n");
}

const PLAN_ARGS = {
  name: "auth refactor",
  plan: "# Auth refactor\n\n## Steps\n\n1. rotate tokens\n2. migrate stores",
};

describe("exit_plan_mode renderer", () => {
  test("registers under the wire tool name", () => {
    expect(pickToolRenderer("exit_plan_mode")).toBe(exitPlanRenderer);
  });

  test("call view shows the plan name and full markdown body", () => {
    const comp = exitPlanRenderer.renderCall!(makeCtx(PLAN_ARGS));
    const out = renderToString(comp);
    expect(out).toContain("● plan auth refactor");
    // Markdown renders the heading (the raw `#` marker is consumed).
    expect(out).toContain("Auth refactor");
    expect(out).toContain("Steps");
    expect(out).toContain("2. migrate stores");
  });

  test("call view degrades to the head line without a plan arg", () => {
    const comp = exitPlanRenderer.renderCall!(makeCtx({ name: "solo" }));
    const out = renderToString(comp);
    expect(out).toContain("● plan solo");
    expect(out).not.toContain("(unnamed)");
  });

  test("result view shows the outcome and saved path, not the plan body", () => {
    const payload: ToolRenderResultPayload = {
      content:
        "Plan submitted for user approval — do not make any changes until the user decides:\n\n" +
        PLAN_ARGS.plan +
        "\n\nSaved to .cetas/plan/auth-refactor_s1.md.",
      isError: false,
    };
    const out = renderToString(
      exitPlanRenderer.renderResult!(
        payload,
        { expanded: false, isPartial: false },
        makeCtx(PLAN_ARGS),
      ),
    );
    expect(out).toContain("● plan auth refactor");
    expect(out).toContain("Plan submitted for user approval");
    expect(out).toContain(".cetas/plan/auth-refactor_s1.md");
    expect(out).not.toContain("2. migrate stores");
  });

  test("error results carry the red bullet and first line", () => {
    const payload: ToolRenderResultPayload = {
      content: "Plan returned for revision: add a rollback step",
      isError: true,
    };
    const out = renderToString(
      exitPlanRenderer.renderResult!(
        payload,
        { expanded: false, isPartial: false },
        makeCtx(PLAN_ARGS),
      ),
    );
    expect(out).toContain("● plan auth refactor");
    expect(out).toContain("add a rollback step");
  });
});
