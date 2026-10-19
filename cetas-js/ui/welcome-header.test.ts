import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import chalk from "chalk";
import { stripTerminalSequences, visibleWidth } from "@earendil-works/pi-tui";
import { renderWelcomeHeader, welcomeWorkspace, WelcomeHeader } from "./welcome-header.ts";

const source = { cwd: "/home/dev/projects/cetas", home: "/home/dev", state: "ready" as const, rows: 36 };
const plain = (lines: string[]) => lines.map(stripTerminalSequences).join("\n");
let detectedColorLevel = chalk.level;
beforeEach(() => { detectedColorLevel = chalk.level; chalk.level = 3; });
afterEach(() => { chalk.level = detectedColorLevel; });

describe("welcome header", () => {
  test("all layouts respect terminal cell width, including CJK and controls", () => {
    for (const state of ["ready", "needs_setup"] as const) {
      for (const width of [-1, 0, 1, 8, 23, 24, 39, 40, 63, 64, 80, 120]) {
        for (const compact of [false, true]) {
          for (const versionInfo of [undefined, { version: "0.8.1", channel: "release" as const }]) {
            const lines = renderWelcomeHeader({ ...source, state, cwd: "/工作区/🧑‍💻/一个很长的项目名称/\x1b[2Jtest\nnext", versionInfo }, width, compact);
            for (const line of lines) {
              expect(visibleWidth(line)).toBeLessThanOrEqual(width);
              expect(line).not.toContain("\x1b[2J");
              expect(line).not.toContain("\n");
            }
          }
        }
      }
    }
  });

  test("version and channel show on the card title row, not in compact mode", () => {
    const versioned = { ...source, versionInfo: { version: "0.8.1", channel: "release" as const } };
    const card = plain(renderWelcomeHeader(versioned, 88));
    expect(card).toContain("0.8.1 · release");
    const narrow = plain(renderWelcomeHeader(versioned, 40));
    expect(narrow).toContain("0.8.1 · release");
    expect(plain(renderWelcomeHeader(versioned, 88, true))).not.toContain("0.8.1");
    // No version info → byte-identical to the legacy card.
    expect(plain(renderWelcomeHeader(source, 88))).not.toContain("· release");
  });

  test("first-run guidance asks for login; ready state suggests starting work", () => {
    const setup = plain(renderWelcomeHeader({ ...source, state: "needs_setup" }, 88));
    expect(setup).toContain("/login");
    expect(setup).not.toContain("Describe a task");
    const ready = plain(renderWelcomeHeader(source, 88));
    expect(ready).toContain("Describe a task");
    expect(ready).toContain("/sessions");
    expect(ready).not.toContain("/login");
  });

  test("compact / short-terminal state leaves room for the conversation", () => {
    expect(renderWelcomeHeader(source, 88, true)).toHaveLength(1);
    expect(renderWelcomeHeader({ ...source, rows: 12 }, 88)).toHaveLength(1);
    expect(renderWelcomeHeader({ ...source, state: "needs_setup", rows: 12 }, 88)).toHaveLength(2);
    expect(renderWelcomeHeader({ ...source, rows: 21 }, 88)).toHaveLength(1);
    expect(renderWelcomeHeader({ ...source, rows: 22 }, 88).length).toBeGreaterThan(1);
  });

  test("narrow cards keep actionable guidance whole", () => {
    for (const state of ["ready", "needs_setup"] as const) {
      const lines = renderWelcomeHeader({ ...source, state }, 40).slice(-3);
      expect(plain(lines)).not.toContain("…");
      expect(plain(lines)).toContain(state === "ready" ? "/help" : "/login");
    }
  });

  test("render reads the latest safe snapshot and can collapse without rebuilding", () => {
    let current = { ...source };
    const component = new WelcomeHeader(() => current);
    expect(plain(component.render(88))).toContain("~/projects/cetas");
    current = { ...current, cwd: "/home/dev/another-workspace" };
    expect(plain(component.render(88))).toContain("~/another-workspace");
    component.compact = true;
    expect(component.render(88)).toHaveLength(1);
  });
});

describe("welcome workspace", () => {
  test("home shortening requires a directory boundary on Unix and Windows", () => {
    expect(welcomeWorkspace("/home/dev/project", "/home/dev/")).toBe("~/project");
    expect(welcomeWorkspace("/home/developer", "/home/dev")).toBe("/home/developer");
    expect(welcomeWorkspace("/home/dev", "/home/dev")).toBe("~");
    expect(welcomeWorkspace("C:\\Users\\dev\\project", "C:\\Users\\dev")).toBe("~\\project");
    expect(welcomeWorkspace("/project", "")).toBe("/project");
  });
});
