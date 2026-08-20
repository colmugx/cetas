import { describe, expect, test } from "bun:test";
import type { Component } from "@earendil-works/pi-tui";

import {
  SkillsOverlay,
  parseSkillActivation,
  parseSkillsOutcome,
  type SkillsEntry,
} from "./skills-overlay.ts";

class FakeTui {
  shown?: Component;
  renders = 0;

  showOverlay(component: Component) {
    this.shown = component;
    return {
      hide: () => {},
      setHidden: () => {},
      isHidden: () => false,
      focus: () => {},
      unfocus: () => {},
      isFocused: () => true,
    };
  }

  requestRender(): void {
    this.renders++;
  }
}

const catalogRaw = JSON.stringify({
  type: "success",
  feedback: "3 skills (project 2, user 1, extra 0)",
  structured: {
    kind: "skills_catalog",
    skills: [
      { name: "tdd", description: "Test-driven development", scope: "project" },
      { name: "ego-browser", description: "Browser automation", scope: "user" },
      { name: "custom", description: "Extra root skill", scope: "extra", root: "/opt/skills" },
    ],
  },
});

describe("skills overlay contract", () => {
  test("parses catalog with scope labels and extra roots", () => {
    const parsed = parseSkillsOutcome(catalogRaw);
    expect(parsed.type).toBe("success");
    if (parsed.type !== "success") return;
    expect(parsed.entries.map((entry) => entry.scope)).toEqual(["project", "user", "extra"]);
    expect(parsed.entries[2]?.root).toBe("/opt/skills");
  });

  test("parses an empty catalog without entries", () => {
    const parsed = parseSkillsOutcome(
      JSON.stringify({
        type: "success",
        feedback: "no skills discovered",
        structured: { kind: "skills_catalog", skills: [] },
      }),
    );
    expect(parsed.type).toBe("success");
    if (parsed.type !== "success") return;
    expect(parsed.entries).toEqual([]);
  });

  test("returns failure outcomes instead of throwing", () => {
    const parsed = parseSkillsOutcome(
      JSON.stringify({ type: "failure", reason: "command not found: skills" }),
    );
    expect(parsed).toEqual({ type: "failure", reason: "command not found: skills" });
  });

  test("rejects malformed catalog rather than showing a fake list", () => {
    expect(() =>
      parseSkillsOutcome(
        JSON.stringify({
          type: "success",
          structured: { kind: "skills_catalog", skills: [{ name: "broken" }] },
        }),
      ),
    ).toThrow("description");
    expect(() =>
      parseSkillsOutcome(
        JSON.stringify({
          type: "success",
          structured: { kind: "other", skills: [] },
        }),
      ),
    ).toThrow("skills_catalog");
  });

  test("parses activation payload for the $name mention path", () => {
    const parsed = parseSkillActivation(
      JSON.stringify({
        type: "success",
        structured: {
          kind: "agent_skill_activation",
          name: "tdd",
          instructions: "Write the test first.",
        },
      }),
    );
    expect(parsed).toEqual({
      type: "success",
      name: "tdd",
      instructions: "Write the test first.",
    });
    const failed = parseSkillActivation(
      JSON.stringify({ type: "failure", reason: "Unknown skill: nope" }),
    );
    expect(failed).toEqual({ type: "failure", reason: "Unknown skill: nope" });
  });

  test("overlay is display-only: enter and escape close without selecting", () => {
    const tui = new FakeTui();
    const overlay = new SkillsOverlay(tui as never);
    let closed = 0;
    overlay.open(
      [
        { name: "tdd", description: "Test-driven development", scope: "project" },
        { name: "grilling", description: "Stress-test a plan", scope: "user" },
      ] as SkillsEntry[],
      () => {
        closed++;
      },
    );
    expect(overlay.isActive).toBe(true);
    // Arrow down moves the cursor; enter/escape dismiss.
    tui.shown!.handleInput!("\u001b[B");
    tui.shown!.handleInput!("\r");
    expect(closed).toBe(1);
    expect(overlay.isActive).toBe(false);
  });

  test("overlay renders an explicit empty state", () => {
    const tui = new FakeTui();
    const overlay = new SkillsOverlay(tui as never);
    overlay.open([], () => {});
    const rendered = tui.shown!.render!(80).join("\n");
    expect(rendered).toContain("No skills discovered");
    // Any key dismisses the empty state.
    tui.shown!.handleInput!("\r");
    expect(overlay.isActive).toBe(false);
  });
});
