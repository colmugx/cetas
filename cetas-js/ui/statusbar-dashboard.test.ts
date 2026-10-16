import { describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { stripTerminalSequences, visibleWidth } from "@earendil-works/pi-tui";
import { readWorkspaceGitBranch, renderStatusbarDashboard } from "./statusbar-dashboard.ts";

const entries = [
  {key:"permission",value:"yolo",color:"warning"},
  {key:"model",value:"glm-5.3-flash:max"},
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
    expect(lines.join("\n")).toMatch(/feature\/agent|more.*statusbar/);
    expect(lines.join("\n")).toContain("Working");
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
      if(width>=70) expect(lines.join("\n")).toContain("Working");
    }
  });
  test("does not silently omit an overflowed group", () => {
    const lines=renderStatusbarDashboard(entries,24,context).join("\n");
    expect(stripTerminalSequences(lines)).toMatch(/more|statusbar/);
  });
  test("never duplicates the ctx self-label", () => {
    expect(stripTerminalSequences(renderStatusbarDashboard(entries,200,context).join("\n")))
      .not.toContain("ctx ctx:");
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
  test("model effort precedes active manager, then lifecycle; never show cetas brand", () => {
    const rows = stripTerminalSequences(renderStatusbarDashboard(entries, 180,
      {...context, manager:"Magpie",status:"Ready"}).join("\n"));
    expect(rows.split("\n")[0]).toMatch(/^ glm-5\.3-flash:max · Magpie Ready/);
    expect(rows).not.toContain("cetas");
    expect(rows).toContain("ctx");
  });
  test("reset and limits are first-class secondary fields, not invented gateway status", () => {
    const sample = [
      {key:"model",value:"GPT-6 Luna:high"},
      {key:"reset",value:"14:30"},
      {key:"5h",value:"62%"},
      {key:"7d",value:"78%"},
      {key:"ctx",value:"38%"},
    ];
    const text = stripTerminalSequences(renderStatusbarDashboard(sample, 120,
      {manager:"Posoco",status:"Rate limited"}).join("\n"));
    expect(text).toContain("GPT-6 Luna:high · Posoco Rate limited");
    expect(text).toContain("Reset 14:30");
    expect(text).toContain("5h 62%");
    expect(text).not.toContain("Gateway connected");
    expect(text).not.toContain("✔");
  });
});


describe("Magpie current model dashboard", () => {
  test("uses manager-selected model and persisted effort when ext-statusbar has no model segment", () => {
    const shown=stripTerminalSequences(renderStatusbarDashboard([{key:"ctx",value:"38%"}],120,
      {manager:"Magpie",status:"Working",selectedModel:"anthropic/claude-sonnet",selectedEffort:"high"}).join("\n"));
    expect(shown).toContain("anthropic/claude-sonnet:high · Magpie Working");
    expect(shown).not.toContain("No model");
  });
  test("does not overwrite Posoco publisher's own model field", () => {
    const shown=stripTerminalSequences(renderStatusbarDashboard(
      [{key:"model",value:"glm-5.3-flash:max"}],120,{manager:"Posoco",status:"Ready"}).join("\n"));
    expect(shown).toContain("glm-5.3-flash:max · Posoco Ready");
  });
});
