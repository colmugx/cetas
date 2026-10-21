import { describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { stripTerminalSequences, visibleWidth } from "@earendil-works/pi-tui";
import { contextOccupancy, readWorkspaceGitBranch, renderStatusbarDashboard } from "./statusbar-dashboard.ts";
import chalk from "chalk";

const entries = [
  {key:"permission",value:"yolo",color:"warning"},
  {key:"model",value:"glm-5.3-flash:max"},
  {key:"manager",value:"Posoco"},
  {key:"ctx",value:"ctx: 30.4K/1.0M · 3%"},
  {key:"cache",value:"0%"},
  {key:"TIME_LIMIT",value:"98% left"},
  {key:"5h",value:"62% left"},
  {key:"ttft",value:"7841ms"},
  {key:"tps",value:"8000.0/s"},
  {key:"avg",value:"8000.0/s"},
  {key:"session",value:"2026-10-16T10-1"},
];
const context = {branch:"feature/agent",status:"Working",activeAgents:2,awaitingReplies:1};
describe("Gate 0.5 adaptive statusbar", () => {
  test("the real-world 10-field input becomes a legible, multi-row dashboard", () => {
    const lines=renderStatusbarDashboard(entries,150,context);
    expect(lines.length).toBeGreaterThanOrEqual(2);
    expect(lines[0]).not.toContain("cetas");
    expect(lines[0]).toContain("Posoco");
    expect(lines[0]).toContain("glm-5.3-flash:max");
    expect(stripTerminalSequences(lines[0])).toContain("⑂ feature/agent");
    expect(stripTerminalSequences(lines[0])).toContain("30.4K/1.0M · 3%");
    expect(lines.join("\n")).not.toContain("Working");
    expect(lines.join("\n")).toContain("2 agents");
    expect(lines.join("\n")).toContain("yolo");
    expect(lines.join("\n")).not.toContain("permission");
    expect(lines.join("\n")).toContain("cache");
    expect(lines.join("\n")).toMatch(/tps|more.*statusbar/);
  });
  test("every line is display-column safe from 1 to 200 columns", () => {
    for(const width of [0,1,2,8,12,24,40,70,80,120,150,200]) {
      const lines=renderStatusbarDashboard(entries,width,context);
      expect(lines.every(line=>visibleWidth(line)<=width)).toBe(true);
      if(width>=24) expect(lines.length).toBeGreaterThanOrEqual(2);
      if(width>=70) {
        expect(stripTerminalSequences(lines[0])).toContain("feature/agent");
        expect(stripTerminalSequences(lines[0])).toContain("30.4K/1.0M");
      }
    }
  });
  test("does not silently omit an overflowed group", () => {
    const lines=renderStatusbarDashboard(entries,24,context).join("\n");
    expect(stripTerminalSequences(lines)).toMatch(/more|statusbar/);
  });
  test("omits ctx self-label entirely", () => {
    const output = stripTerminalSequences(renderStatusbarDashboard(entries, 200, context).join("\n"));
    expect(output).toContain("30.4K/1.0M · 3%");
    expect(output).not.toContain("ctx");
  });
  test("git branch from nested workspace and worktree .git file", () => {
    const root=mkdtempSync(join(tmpdir(),"cetas-statusbar-"));
    try {
      mkdirSync(join(root,".git"));mkdirSync(join(root,"nested"));
      writeFileSync(join(root,".git","HEAD"),"ref: refs/heads/feature/testing\n");
      expect(readWorkspaceGitBranch(join(root,"nested"))).toBe("feature/testing");
    } finally {rmSync(root,{recursive:true,force:true});}
  });
  test("a pending question is a count, never the status word", () => {
    const output = stripTerminalSequences(
      renderStatusbarDashboard(entries, 200, {...context, status:"Ready", pendingUserQuestions:2}).join("\n"));
    expect(output).toContain("? 2 to answer");
    // The turn is not blocked: "Ready" stays unrendered and the status never
    // changes to a waiting word.
    expect(output).not.toContain("Ready");
    const none = stripTerminalSequences(
      renderStatusbarDashboard(entries, 200, {...context, status:"Ready", pendingUserQuestions:0}).join("\n"));
    expect(none).not.toContain("to answer");
  });
});

describe("fixed semantic statusbar hierarchy", () => {
  test("model effort precedes manager, git branch and context; never show lifecycle", () => {
    const rows = stripTerminalSequences(renderStatusbarDashboard(entries, 180,
      {...context, status:"Ready"}).join("\n"));
    expect(rows.split("\n")[0]).toBe(
      " glm-5.3-flash:max · Posoco ⑂ feature/agent · 30.4K/1.0M · 3%");
    expect(rows).not.toContain("cetas");
    expect(rows).not.toContain("Ready");
    expect(rows).not.toContain("ctx");
  });
  test("reset and limits are first-class secondary fields, not invented gateway status", () => {
    const sample = [
      {key:"model",value:"GPT-6 Luna:high"},
      {key:"manager",value:"Posoco"},
      {key:"reset",value:"14:30"},
      {key:"5h",value:"62%"},
      {key:"7d",value:"78%"},
      {key:"ctx",value:"38%"},
    ];
    const text = stripTerminalSequences(renderStatusbarDashboard(sample, 120,
      {status:"Rate limited"}).join("\n"));
    expect(text).toContain("GPT-6 Luna:high · Posoco · 38%");
    expect(text).not.toContain("Rate limited");
    expect(text).not.toContain("ctx");
    expect(text).toContain("Reset 14:30");
    expect(text).toContain("5h 62% · 7d 78%");
    expect(text).not.toContain("Gateway connected");
    expect(text).not.toContain("✔");
  });
  test("permission leads the secondary rows unlabeled; quota windows stay one group", () => {
    const rows = stripTerminalSequences(renderStatusbarDashboard([
      {key:"model",value:"GPT-6 Luna:high"},
      {key:"5h",value:"62% left"},
      {key:"permission",value:"yolo",color:"warning"},
      {key:"weekly",value:"78% left"},
      {key:"session",value:"2026-10-16T10-1"},
    ], 200, {}).join("\n")).split("\n");
    expect(rows[1]).toBe(
      " yolo · 5h 62% left · weekly 78% left · session 2026-10-16T10-1");
    expect(rows.join("\n")).not.toContain("permission");
  });
});

describe("model manager presentation contract", () => {
  test("independent manager segment is rendered without implementation-dependent context", () => {
    for (const label of ["Posoco", "Magpie", "Third-party manager"]) {
      const value = stripTerminalSequences(renderStatusbarDashboard([
        { key:"model", value:"model:high" }, { key:"manager", value:label },
      ], 120, { status:"Working" }).join("\n"));
      expect(value).toContain(`model:high · ${label}`);
      expect(value).not.toContain("Working");
      expect(value).not.toContain("No model");
    }
  });
  test("missing manager publication never fabricates a particular backend", () => {
    const value = stripTerminalSequences(renderStatusbarDashboard([
      {key:"model",value:"model:default"},
    ],100,{status:"Ready"}).join("\n"));
    expect(value).toContain("model:default");
    expect(value).not.toContain("Ready");
    expect(value).not.toContain("Posoco");
    expect(value).not.toContain("Magpie");
  });
});

describe("provider-qualified model status", () => {
  test("distinguishes an aggregate provider from the official provider", () => {
    const aggregate = stripTerminalSequences(renderStatusbarDashboard([
      {key:"model",value:"deepseek-v4.1-flash:high"},
      {key:"model_slot",value:"opencode-go/deepseek-v4.1-flash"},
      {key:"manager",value:"Posoco"},
    ],120,{branch:"main"})[0]);
    expect(aggregate).toBe(" opencode-go/deepseek-v4.1-flash:high · Posoco ⑂ main");

    const official = stripTerminalSequences(renderStatusbarDashboard([
      {key:"model",value:"deepseek-flash:high"},
      {key:"model_slot",value:"deepseek/deepseek-flash"},
      {key:"manager",value:"Posoco"},
    ],120)[0]);
    expect(official).toBe(" deepseek/deepseek-flash:high · Posoco");
  });

  test("keeps the live effort suffix, without repeating the slot in details", () => {
    for (const effort of ["low", "medium", "high"]) {
      const result = stripTerminalSequences(renderStatusbarDashboard([
        {key:"model",value:`deepseek-v4.1-flash:${effort}`},
        {key:"model_slot",value:"opencode-go/deepseek-v4.1-flash"},
        {key:"permission",value:"yolo"},
      ],120).join("\n"));
      expect(result).toContain(`opencode-go/deepseek-v4.1-flash:${effort}`);
      expect(result).not.toContain("model_slot");
      expect(result.split("opencode-go/")).toHaveLength(2);
    }
  });

  test("without a slot segment preserves the publisher's opaque model value", () => {
    const result = stripTerminalSequences(renderStatusbarDashboard([
      {key:"model",value:"model:provider/variant:low"},
    ],120)[0]);
    expect(result).toBe(" model:provider/variant:low");
  });
});

describe("opaque model selection values", () => {
  test("model-prefixed IDs are never interpreted as duplicated display labels", () => {
    for (const value of ["model:high", "model:default", "model:provider/variant:low"]) {
      const rendered = stripTerminalSequences(renderStatusbarDashboard([
        {key:"model", value},
        {key:"manager", value:"Custom Model Router"},
      ], 120, {status:"Ready"}).join("\n"));
      expect(rendered).toContain(value);
      expect(rendered).toContain("Custom Model Router");
      expect(rendered).not.toContain("Ready");
    }
  });

  test("other labeled metrics still normalize duplicated labels", () => {
    const rendered = stripTerminalSequences(renderStatusbarDashboard([
      {key:"model",value:"glm-5.3-flash:max"},
      {key:"ctx",value:"ctx: 30.4K/1.0M"},
    ],140,{status:"Working"}).join("\n"));
    expect(rendered).toContain("glm-5.3-flash:max · 30.4K/1.0M");
    expect(rendered).not.toContain("ctx");
  });
});

describe("left-aligned context placement", () => {
  test("context follows the branch without any right-justifying spaces", () => {
    const first = stripTerminalSequences(renderStatusbarDashboard([
      {key:"model",value:"gpt-6:high"},
      {key:"manager",value:"Posoco"},
      {key:"ctx",value:"ctx: 30.4K/1.0M"},
    ],160,{branch:"feature/demo",status:"Working"})[0]);
    expect(first).toBe(" gpt-6:high · Posoco ⑂ feature/demo · 30.4K/1.0M");
  });

  test("context wraps before lower-priority metrics when the header is full", () => {
    const rows = renderStatusbarDashboard([
      {key:"model",value:"gpt-6:high"},
      {key:"manager",value:"Posoco"},
      {key:"ctx",value:"ctx: 30.4K/1.0M · 3%"},
      {key:"cache",value:"0%"},
    ],38,{branch:"feature/demo",status:"Working"})
      .map(stripTerminalSequences);
    expect(rows[0]).toContain("⑂ feature/demo");
    expect(rows[0]).not.toContain("30.4K");
    expect(rows[1]).toContain("30.4K/1.0M · 3%");
    expect(rows.join("\n")).not.toMatch(/Working|ctx/);
  });

  test("missing git branch does not restore a Ready/Working placeholder", () => {
    const first = stripTerminalSequences(renderStatusbarDashboard([
      {key:"model",value:"gpt-6:high"},
      {key:"manager",value:"Posoco"},
      {key:"ctx",value:"ctx: 5%"},
    ],120,{status:"Working"})[0]);
    expect(first).toBe(" gpt-6:high · Posoco · 5%");
  });
});

describe("git branch accent color", () => {
  test("branch name uses #9BE1A1 and marker remains muted", () => {
    const originalLevel = chalk.level;
    try {
      chalk.level = 3;
      const first = renderStatusbarDashboard([
        {key:"model",value:"gpt-6:high"},
        {key:"manager",value:"Posoco"},
        {key:"ctx",value:"ctx: 5%"},
      ],120,{branch:"feature/demo"})[0];
      expect(first).toContain("\x1b[38;2;155;225;161mfeature/demo\x1b[39m");
      expect(first).not.toContain("\x1b[38;2;155;225;161m⑂");
      expect(stripTerminalSequences(first))
        .toBe(" gpt-6:high · Posoco ⑂ feature/demo · 5%");
    } finally {
      chalk.level = originalLevel;
    }
  });
});

describe("core context status fallback", () => {
  const state = { source: "measured", last_measured_tokens: 24000,
    estimated_added_tokens: 1000, window_tokens: 100000 };
  test("formats a measured reading and marks estimated additions", () => {
    expect(contextOccupancy(state)).toBe("~25.0K/100.0K · 25%");
    expect(contextOccupancy({...state, estimated_added_tokens: 0}))
      .toBe("24.0K/100.0K · 24%");
  });
  test("never invents occupancy for unknown or invalid readings", () => {
    expect(contextOccupancy({...state, source: "unknown", last_measured_tokens: null}))
      .toBe("?/100.0K");
    expect(contextOccupancy({...state, last_measured_tokens: null}))
      .toBe("?/100.0K");
    expect(contextOccupancy({...state, window_tokens: 0}))
      .toBe("~25.0K");
    expect(contextOccupancy({source: "bogus"})).toBeUndefined();
  });
  test("uses Core context only when no extension ctx segment exists", () => {
    const without = stripTerminalSequences(renderStatusbarDashboard(
      [{key:"model",value:"single-model"}], 120, {contextValue:"~25.0K/100.0K · 25%"}
    ).join(" "));
    expect(without).toContain("~25.0K/100.0K · 25%");
    const withExtension = stripTerminalSequences(renderStatusbarDashboard(
      [{key:"model",value:"single-model"},{key:"ctx",value:"ctx: 9.0K/20.0K"}],
      120, {contextValue:"~25.0K/100.0K · 25%"}
    ).join(" "));
    expect(withExtension).toContain("9.0K/20.0K");
    expect(withExtension).not.toContain("25.0K/100.0K");
  });
});
