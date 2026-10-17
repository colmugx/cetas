import { describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { stripTerminalSequences, visibleWidth } from "@earendil-works/pi-tui";
import { readWorkspaceGitBranch, renderStatusbarDashboard } from "./statusbar-dashboard.ts";
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
    expect(lines.join("\n")).toContain("permission");
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
    expect(text).toContain("5h 62%");
    expect(text).not.toContain("Gateway connected");
    expect(text).not.toContain("✔");
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
