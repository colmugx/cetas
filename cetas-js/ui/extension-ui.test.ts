import { describe, expect, test } from "bun:test";
import chalk from "chalk";
import { Container, visibleWidth, type Component } from "@earendil-works/pi-tui";

import {
  UiRenderHost,
  UiRequestBar,
  createUiRenderCallback,
  createUiRequestCallback,
  formatStatusValue,
} from "./extension-ui.ts";
import { roleStyle, theme } from "./theme.ts";

class FakeTui {
  renderCount = 0;
  focused?: Component;

  requestRender(): void {
    this.renderCount++;
  }

  setFocus(component: Component | null): void {
    this.focused = component ?? undefined;
  }
}

/** Swap console.warn for a recorder; call restore() when done. */
function captureWarn(): { warns: string[]; restore(): void } {
  const warns: string[] = [];
  const original = console.warn;
  console.warn = (...args: unknown[]) => {
    warns.push(args.map((item) => String(item)).join(" "));
  };
  return {
    warns,
    restore: () => {
      console.warn = original;
    },
  };
}

describe("UiRenderHost", () => {
  test("replaces a keyed render instead of appending", () => {
    const tui = new FakeTui();
    const status = new Container();
    const notice = new Container();
    const widget = new Container();
    const host = new UiRenderHost(tui as never, { status, notice, widget });

    host.render({
      slot: "status",
      key: "goal.status",
      title: "Goal",
      body: { type: "text", text: "first" },
    });
    host.render({
      slot: "status",
      key: "goal.status",
      title: "Goal",
      body: { type: "text", text: "second" },
    });

    expect(status.children).toHaveLength(1);
    expect(status.render(80).join("\n")).toContain("second");
    expect(status.render(80).join("\n")).not.toContain("first");
    expect(tui.renderCount).toBe(2);
  });

  test("maps render slots to independent mounts", () => {
    const tui = new FakeTui();
    const status = new Container();
    const notice = new Container();
    const widget = new Container();
    const host = new UiRenderHost(tui as never, { status, notice, widget });

    host.render({
      slot: "notice",
      key: "workflow.notice",
      title: "Workflow",
      body: { type: "lines", lines: ["one", "two"] },
    });
    host.render({
      slot: "widget",
      key: "goal.values",
      title: "Goal",
      body: {
        type: "key_value",
        entries: [{ key: "state", value: "running" }],
      },
    });

    expect(status.children).toHaveLength(0);
    expect(notice.render(80).join("\n")).toContain("• one");
    expect(widget.render(80).join("\n")).toContain("running");
  });

  test("rejects invalid progress rather than clamping it", () => {
    const tui = new FakeTui();
    const host = new UiRenderHost(tui as never, {
      status: new Container(),
      notice: new Container(),
      widget: new Container(),
    });

    expect(() =>
      host.render({
        slot: "status",
        key: "invalid",
        title: "Invalid",
        body: { type: "progress", current: 1.1 },
      }),
    ).toThrow("within [0, 1]");
  });

  // Regression: the rendered map used to be keyed by the bare key, so the
  // same key rendered into two slots evicted the first mount.
  test("keeps same-key renders in different slots independent", () => {
    const tui = new FakeTui();
    const status = new Container();
    const widget = new Container();
    const host = new UiRenderHost(tui as never, {
      status,
      notice: new Container(),
      widget,
    });

    host.render({
      slot: "status",
      key: "main",
      title: "Status",
      body: { type: "text", text: "status-main" },
    });
    host.render({
      slot: "widget",
      key: "main",
      title: "Widget",
      body: { type: "text", text: "widget-main" },
    });

    expect(status.children).toHaveLength(1);
    expect(widget.children).toHaveLength(1);

    // Re-rendering one slot must not evict the other.
    host.render({
      slot: "status",
      key: "main",
      title: "Status",
      body: { type: "text", text: "status-v2" },
    });
    expect(status.children).toHaveLength(1);
    expect(widget.children).toHaveLength(1);
    expect(status.render(80).join("\n")).toContain("status-v2");
    expect(widget.render(80).join("\n")).toContain("widget-main");

    // Removal is slot-scoped too.
    host.remove("widget", "main");
    expect(widget.children).toHaveLength(0);
    expect(status.children).toHaveLength(1);
  });

  test("routes a keyed render to its dedicated mount instead of the slot mount", () => {
    const tui = new FakeTui();
    const status = new Container();
    const statusBar = new Container();
    const host = new UiRenderHost(
      tui as never,
      { status, notice: new Container(), widget: new Container() },
      { "status:statusbar": { mount: statusBar } },
    );

    host.render({
      slot: "status",
      key: "statusbar",
      title: "Status",
      body: { type: "text", text: "routed" },
    });
    host.render({
      slot: "status",
      key: "other",
      title: "Other",
      body: { type: "text", text: "default" },
    });

    expect(status.render(80).join("\n")).toContain("default");
    expect(status.render(80).join("\n")).not.toContain("routed");
    expect(statusBar.render(80).join("\n")).toContain("routed");
  });

  test("renders a routed key_value body as a single status-bar line", () => {
    const tui = new FakeTui();
    const statusBar = new Container();
    const host = new UiRenderHost(
      tui as never,
      { status: new Container(), notice: new Container(), widget: new Container() },
      { "status:statusbar": { mount: statusBar, format: "line" } },
    );

    host.render({
      slot: "status",
      key: "statusbar",
      title: "Status",
      body: {
        type: "key_value",
        entries: [
          { key: "model", value: "deepseek-v4-pro" },
          { key: "effort", value: "high" },
          { key: "tok", value: "10↑ 2↓" },
        ],
      },
    });

    const lines = statusBar.render(80);
    expect(lines).toHaveLength(1);
    const line = lines[0]!;
    // Every segment is a muted `key:` label plus its value; the role-less
    // first value keeps the legacy bold treatment. Assertions recompose the
    // expected fragments from the theme so they hold at any chalk level.
    expect(line).toContain(`${theme.muted("model:")} ${theme.bold("deepseek-v4-pro")}`);
    expect(line).toContain(`${theme.muted("effort:")} high`);
    expect(line).toContain(`${theme.muted("tok:")} 10↑ 2↓`);
    // One muted ` | ` separator between ALL segments; the title is dropped.
    expect(line.split(theme.muted(" | "))).toHaveLength(3);
    expect(line).not.toContain("Status");
  });

  test("renders a routed entries body as the same single status-bar line", () => {
    const tui = new FakeTui();
    const statusBar = new Container();
    const host = new UiRenderHost(
      tui as never,
      { status: new Container(), notice: new Container(), widget: new Container() },
      { "status:statusbar": { mount: statusBar, format: "line" } },
    );

    host.render({
      slot: "status",
      key: "statusbar",
      title: "Status",
      body: {
        type: "entries",
        entries: [
          { key: "model", value: "deepseek-v4-pro" },
          { key: "plan", value: "pro", color: "accent" },
          { key: "resume", value: "12:00", color: "warning" },
          { key: "session", value: "s1" },
        ],
      },
    });

    const lines = statusBar.render(80);
    expect(lines).toHaveLength(1);
    const line = lines[0]!;
    // Role values take their theme style; the trailing role-less value
    // stays plain.
    expect(line).toContain(`${theme.muted("model:")} ${theme.bold("deepseek-v4-pro")}`);
    expect(line).toContain(`${theme.muted("plan:")} ${theme.accent("pro")}`);
    expect(line).toContain(`${theme.muted("resume:")} ${theme.warning("12:00")}`);
    expect(line).toContain(`${theme.muted("session:")} s1`);
    expect(line.split(theme.muted(" | "))).toHaveLength(4);
  });

  test("renders the 🕐 reset announcement with a localized reset moment", () => {
    const tui = new FakeTui();
    const statusBar = new Container();
    const host = new UiRenderHost(
      tui as never,
      { status: new Container(), notice: new Container(), widget: new Container() },
      { "status:statusbar": { mount: statusBar, format: "line" } },
    );

    host.render({
      slot: "status",
      key: "statusbar",
      title: "Status",
      body: {
        type: "entries",
        entries: [
          { key: "🕐 5h reset", value: "2026-09-04T00:15:26Z", color: "warning" },
        ],
      },
    });

    const line = statusBar.render(80).join("\n");
    expect(line).toContain("🕐 5h reset:");
    expect(line).not.toContain("2026-09-04T00:15:26Z");
    expect(line).toMatch(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/);
  });

  test("renders an empty routed key_value line as blank", () => {
    const tui = new FakeTui();
    const statusBar = new Container();
    const host = new UiRenderHost(
      tui as never,
      { status: new Container(), notice: new Container(), widget: new Container() },
      { "status:statusbar": { mount: statusBar, format: "line" } },
    );

    host.render({
      slot: "status",
      key: "statusbar",
      title: "Status",
      body: { type: "key_value", entries: [] },
    });

    expect(statusBar.render(80).join("\n").trim()).toBe("");
  });

  test("keeps the default body format for routed keys without a line format", () => {
    const tui = new FakeTui();
    const statusBar = new Container();
    const host = new UiRenderHost(
      tui as never,
      { status: new Container(), notice: new Container(), widget: new Container() },
      { "status:statusbar": { mount: statusBar } },
    );

    host.render({
      slot: "status",
      key: "statusbar",
      title: "Status",
      body: {
        type: "key_value",
        entries: [{ key: "model", value: "deepseek-v4-pro" }],
      },
    });

    const rendered = statusBar.render(80).join("\n");
    expect(rendered).toContain("Status");
    expect(rendered).toContain("model");
    expect(rendered).toContain("deepseek-v4-pro");
  });
});

describe("formatStatusValue", () => {
  test("renders the UTC timestamp convention as local yyyy-mm-dd hh:mm:ss", () => {
    const utc = "2026-09-04T00:15:26Z";
    const rendered = formatStatusValue(utc);
    // The devkit convention never survives rendering as-is.
    expect(rendered).not.toBe(utc);
    expect(rendered).toMatch(/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/);
    // The digits come from the same local clock a user reads: mirror the
    // conversion with plain Date getters so the assertion holds in any TZ.
    const date = new Date(utc);
    const pad = (n: number) => String(n).padStart(2, "0");
    expect(rendered).toBe(
      `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
        ` ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`,
    );
  });

  test("preserves an exact local reset date with zero-padded fields", () => {
    const localReset = new Date(2026, 0, 2, 3, 4, 5);
    const utcReset = localReset.toISOString().replace(".000Z", "Z");

    expect(formatStatusValue(utcReset)).toBe("2026-01-02 03:04:05");
  });

  test("leaves every non-timestamp value untouched", () => {
    for (const value of ["12:00", "deepseek-v4-pro", "s1", "5h 92%"]) {
      expect(formatStatusValue(value)).toBe(value);
    }
  });
});

describe("roleStyle", () => {  test("maps the six vocabulary roles onto the matching theme styles", () => {
    expect(roleStyle("accent")).toBe(theme.accent);
    expect(roleStyle("warning")).toBe(theme.warning);
    expect(roleStyle("error")).toBe(theme.error);
    expect(roleStyle("success")).toBe(theme.success);
    expect(roleStyle("info")).toBe(theme.info);
    expect(roleStyle("muted")).toBe(theme.muted);
  });

  test("known roles actually style text when color output is enabled", () => {
    const detectedLevel = chalk.level;
    chalk.level = 3;
    try {
      // Guards the premise of the mapping above: with color forced on, a
      // mapped role must differ from plain text.
      expect(theme.accent("x")).not.toBe("x");
      expect(roleStyle("success")("ok")).toBe(theme.success("ok"));
    } finally {
      chalk.level = detectedLevel;
    }
  });

  test("unknown roles degrade to identity passthrough", () => {
    expect(roleStyle("beige")("plain")).toBe("plain");
    expect(roleStyle("")("plain")).toBe("plain");
  });
});

describe("createUiRenderCallback FFI guard", () => {
  function makeCallback() {
    const tui = new FakeTui();
    const status = new Container();
    const notice = new Container();
    const widget = new Container();
    const host = new UiRenderHost(tui as never, { status, notice, widget });
    return { status, notice, widget, callback: createUiRenderCallback(host) };
  }

  test("malformed json does not throw and renders nothing", () => {
    const { status, notice, widget, callback } = makeCallback();
    const { warns, restore } = captureWarn();
    try {
      expect(() => callback("{broken json")).not.toThrow();
      expect(status.children).toHaveLength(0);
      expect(notice.children).toHaveLength(0);
      expect(widget.children).toHaveLength(0);
    } finally {
      restore();
    }
    expect(warns).toHaveLength(1);
  });

  test("wrong type tag, malformed body, and huge payloads warn bounded", () => {
    const { status, widget, callback } = makeCallback();
    const { warns, restore } = captureWarn();
    try {
      expect(() => callback('{"type":"ui_request"}')).not.toThrow();
      expect(() =>
        callback(
          '{"type":"ui_render","render":{"slot":"status","key":"k","title":"t","body":{"type":"text"}}}',
        ),
      ).not.toThrow();
      expect(() => callback("x".repeat(500))).not.toThrow();
    } finally {
      restore();
    }
    expect(warns).toHaveLength(3);
    for (const warn of warns) {
      // Reason is bounded to 120 and the payload to ~200, prefix aside.
      expect(warn.length).toBeLessThanOrEqual(360);
    }
    expect(status.children).toHaveLength(0);
    expect(widget.children).toHaveLength(0);
  });

  test("a valid render still renders after previous drops", () => {
    const { status, callback } = makeCallback();
    const { restore } = captureWarn();
    try {
      callback("{broken");
      callback(
        JSON.stringify({
          type: "ui_render",
          render: {
            slot: "status",
            key: "goal.status",
            title: "Goal",
            body: { type: "text", text: "alive" },
          },
        }),
      );
    } finally {
      restore();
    }
    expect(status.render(80).join("\n")).toContain("alive");
  });
});

describe("entries bodies over the FFI guard", () => {
  function makeLineCallback() {
    const tui = new FakeTui();
    const statusBar = new Container();
    const host = new UiRenderHost(
      tui as never,
      { status: new Container(), notice: new Container(), widget: new Container() },
      { "status:statusbar": { mount: statusBar, format: "line" } },
    );
    return { statusBar, callback: createUiRenderCallback(host) };
  }

  function entriesEvent(entries: unknown): string {
    return JSON.stringify({
      type: "ui_render",
      render: {
        slot: "status",
        key: "statusbar",
        title: "Status",
        body: { type: "entries", entries },
      },
    });
  }

  test("parses entries with and without color roles onto one status-bar line", () => {
    const { statusBar, callback } = makeLineCallback();
    const { restore } = captureWarn();
    try {
      callback(
        entriesEvent([
          { key: "model", value: "deepseek-v4-pro" },
          { key: "plan", value: "pro", color: "accent" },
          { key: "session", value: "s1" },
        ]),
      );
    } finally {
      restore();
    }
    expect(statusBar.children).toHaveLength(1);
    const line = statusBar.render(80).join("\n");
    expect(line).toContain(`${theme.muted("model:")} ${theme.bold("deepseek-v4-pro")}`);
    expect(line).toContain(`${theme.muted("plan:")} ${theme.accent("pro")}`);
    expect(line).toContain(`${theme.muted("session:")} s1`);
    expect(line.split(theme.muted(" | "))).toHaveLength(3);
  });

  test("a non-string color role drops the render like any malformed body", () => {
    const { statusBar, callback } = makeLineCallback();
    const { warns, restore } = captureWarn();
    try {
      callback(entriesEvent([{ key: "plan", value: "pro", color: 3 }]));
    } finally {
      restore();
    }
    expect(statusBar.children).toHaveLength(0);
    expect(warns).toHaveLength(1);
    expect(warns[0]).toContain("color must be a string");
  });

  test("a non-object entry drops the render", () => {
    const { statusBar, callback } = makeLineCallback();
    const { warns, restore } = captureWarn();
    try {
      callback(entriesEvent(["not-an-entry"]));
    } finally {
      restore();
    }
    expect(statusBar.children).toHaveLength(0);
    expect(warns).toHaveLength(1);
    expect(warns[0]).toContain("must be an object");
  });
});

describe("UiRequestBar", () => {
  function makeBar() {
    const tui = new FakeTui();
    const mount = new Container();
    const restores: number[] = [];
    const bar = new UiRequestBar(tui as never, mount, () => restores.push(1));
    return { tui, mount, restores, bar };
  }

  test("resolves a select request from the focused inline panel", async () => {
    const { tui, mount, restores, bar } = makeBar();
    const responsePromise = bar.request({
      type: "select",
      title: "Choose",
      options: ["alpha", "beta"],
      default_index: 1,
    });

    expect(tui.focused).toBeDefined();
    expect(mount.children).toHaveLength(1);
    tui.focused!.handleInput!("\r");

    await expect(responsePromise).resolves.toEqual({
      type: "selected",
      index: 1,
    });
    expect(mount.children).toHaveLength(0);
    expect(restores).toHaveLength(1);
  });

  test("renders the buttons in one bottom row with a highlighted selection", async () => {
    // Force color output so the background block is assertable; restore
    // the detected level afterwards.
    const detectedLevel = chalk.level;
    chalk.level = 3;
    try {
      const { tui, mount, bar } = makeBar();
      const pending = bar.request({
        type: "select",
        title: "Allow tool 'bash' (shell)?",
        options: ["Allow once", "Allow for this session", "Deny"],
      });

      const row = mount
        .render(60)
        .find(
          (line) => line.includes("Allow once") && line.includes("Deny"),
        );
      expect(row).toBeDefined();
      expect(row).toContain(chalk.bold.bgCyan.black(" Allow once "));
      expect(row).toContain(" Allow for this session ");

      // Right arrow moves the block onto the next button.
      tui.focused!.handleInput!("\u001b[C");
      const moved = mount
        .render(60)
        .find((line) => line.includes("Allow once"));
      expect(moved).toContain(chalk.bold.bgCyan.black(" Allow for this session "));
      expect(moved).not.toContain(chalk.bold.bgCyan.black(" Allow once "));

      tui.focused!.handleInput!("\u001b");
      await expect(pending).resolves.toEqual({ type: "cancelled" });
    } finally {
      chalk.level = detectedLevel;
    }
  });

  test("row layout moves only with left/right, never up/down", async () => {
    const detectedLevel = chalk.level;
    chalk.level = 3;
    try {
      const { tui, mount, bar } = makeBar();
      const pending = bar.request({
        type: "select",
        title: "Choose",
        options: ["Allow once", "Allow for this session", "Deny"],
      });

      mount.render(60);
      const row = () =>
        mount.render(60).find((line) => line.includes("Allow once")) ?? "";

      // Up is not a row key: the selection stays put.
      tui.focused!.handleInput!("\u001b[A");
      expect(row()).toContain(chalk.bold.bgCyan.black(" Allow once "));

      // Left wraps to the last button; right steps back to the first.
      tui.focused!.handleInput!("\u001b[D");
      expect(row()).toContain(chalk.bold.bgCyan.black(" Deny "));
      expect(row()).not.toContain(chalk.bold.bgCyan.black(" Allow once "));

      tui.focused!.handleInput!("\u001b[C");
      expect(row()).toContain(chalk.bold.bgCyan.black(" Allow once "));

      bar.cancel();
      await expect(pending).resolves.toEqual({ type: "cancelled" });
    } finally {
      chalk.level = detectedLevel;
    }
  });

  test("stacked layout moves only with up/down, never left/right", async () => {
    const detectedLevel = chalk.level;
    chalk.level = 3;
    try {
      const { tui, mount, bar } = makeBar();
      const pending = bar.request({
        type: "select",
        title: "Choose",
        options: ["Allow once", "Allow for this session", "Deny"],
      });

      mount.render(24);
      const lineFor = (label: string) =>
        mount.render(24).find((line) => line.includes(label)) ?? "";
      // The stacked selection renders as a full-width bgCyan block (46).
      const isSelectionRow = (label: string) =>
        lineFor(label).includes("\u001b[46m");

      // Right is not a stacked-list key: the selection stays put.
      tui.focused!.handleInput!("\u001b[C");
      expect(isSelectionRow("Allow once")).toBe(true);

      // Down moves one entry.
      tui.focused!.handleInput!("\u001b[B");
      expect(isSelectionRow("Allow once")).toBe(false);
      expect(isSelectionRow("Allow for this session")).toBe(true);

      bar.cancel();
      await expect(pending).resolves.toEqual({ type: "cancelled" });
    } finally {
      chalk.level = detectedLevel;
    }
  });

  test("stacks the buttons when the row cannot fit the width", async () => {
    const { mount, bar } = makeBar();
    const pending = bar.request({
      type: "select",
      title: "Allow tool 'bash' (shell)?",
      options: ["Allow once", "Allow for this session", "Deny"],
    });

    const labelLines = mount
      .render(24)
      .filter((line) =>
        ["Allow once", "Allow for this session", "Deny"].some((label) =>
          line.includes(label),
        ),
      );
    expect(labelLines).toHaveLength(3);

    bar.cancel();
    await expect(pending).resolves.toEqual({ type: "cancelled" });
  });

  // Regression for the crash "Rendered line exceeds terminal width": the
  // permission ask embeds an arguments-preview JSON line in the select
  // title; CJK content made it wider than the terminal even though it was
  // char-capped upstream. Every panel line must fit the render width.
  test("truncates title and detail lines to the render width", async () => {
    const { mount, bar } = makeBar();
    const argsPreview =
      '{"path":"小红书/01-国产新语言MoonBit有多猛.md","content":"# 01 · 国产新语言 MoonBit 有多猛？它已经能跑';
    const pending = bar.request({
      type: "select",
      title: `Allow tool 'obsidian_create_note' (unknown)?\n${argsPreview}`,
      options: ["Allow once", "Allow for this session", "Deny"],
    });

    const lines = mount.render(95);
    for (const line of lines) {
      expect(visibleWidth(line)).toBeLessThanOrEqual(95);
    }
    const detail = lines.find((line) => line.includes("小红书"));
    expect(detail).toBeDefined();

    bar.cancel();
    await expect(pending).resolves.toEqual({ type: "cancelled" });
  });

  test("resolves an input request from the inline field", async () => {
    const { tui, bar } = makeBar();
    const responsePromise = bar.request({
      type: "input",
      prompt: "Name",
      placeholder: "e.g. release-1",
    });

    tui.focused!.handleInput!("a");
    tui.focused!.handleInput!("\r");

    await expect(responsePromise).resolves.toEqual({ type: "text", text: "a" });
  });

  test("a newer ask auto-cancels the older concurrent one", async () => {
    const { tui, mount, restores, bar } = makeBar();
    const first = bar.request({
      type: "confirm",
      prompt: "Continue?",
      default_yes: true,
    });
    const second = bar.request({
      type: "input",
      prompt: "Name",
    });

    // The older ask settled as cancelled; the newer one is what's presented.
    await expect(first).resolves.toEqual({ type: "cancelled" });
    expect(mount.children).toHaveLength(1);
    expect(tui.focused).toBeDefined();

    tui.focused!.handleInput!("ok");
    tui.focused!.handleInput!("\r");
    await expect(second).resolves.toEqual({ type: "text", text: "ok" });
    expect(mount.children).toHaveLength(0);
    expect(restores).toHaveLength(2);
    expect(bar.isActive()).toBe(false);
  });

  test("auto-cancel leaves the bar cancellable during host shutdown", async () => {
    const { mount, bar } = makeBar();
    const first = bar.request({ type: "input", prompt: "One" });
    const second = bar.request({ type: "input", prompt: "Two" });
    await expect(first).resolves.toEqual({ type: "cancelled" });

    bar.cancel();
    await expect(second).resolves.toEqual({ type: "cancelled" });
    expect(mount.children).toHaveLength(0);
  });

  test("cancels an active request during host shutdown", async () => {
    const { mount, restores, bar } = makeBar();
    const response = bar.request({
      type: "input",
      prompt: "Name",
    });

    bar.cancel();

    await expect(response).resolves.toEqual({ type: "cancelled" });
    expect(mount.children).toHaveLength(0);
    expect(restores).toHaveLength(1);
  });

  test("builds a correlated ui_response for the MoonBit Promise bridge", async () => {
    const { tui, bar } = makeBar();
    const callback = createUiRequestCallback(bar, 1_000);
    const responsePromise = callback(
      JSON.stringify({
        type: "ui_request",
        request_id: "request-7",
        request: {
          type: "confirm",
          prompt: "Apply?",
          default_yes: false,
        },
      }),
    );

    tui.focused!.handleInput!("\r");

    await expect(responsePromise).resolves.toBe(
      JSON.stringify({
        type: "ui_response",
        request_id: "request-7",
        response: { type: "no" },
      }),
    );
  });

  test("answers malformed request events with a correlated ui_response error", async () => {
    const { bar } = makeBar();
    const callback = createUiRequestCallback(bar, 1_000);
    const { restore } = captureWarn();
    try {
      // Unparseable bytes: no request_id is recoverable.
      await expect(callback("{broken")).resolves.toBe(
        JSON.stringify({
          type: "ui_response",
          request_id: "unknown",
          error: { code: "malformed_request" },
        }),
      );
      // Recoverable request_id is echoed even when the payload is malformed.
      await expect(
        callback(
          JSON.stringify({
            type: "ui_request",
            request_id: "request-8",
            request: { type: "confirm", prompt: "x" },
          }),
        ),
      ).resolves.toBe(
        JSON.stringify({
          type: "ui_response",
          request_id: "request-8",
          error: { code: "malformed_request" },
        }),
      );
      // An empty request_id is not recoverable.
      await expect(
        callback(
          JSON.stringify({
            type: "ui_request",
            request_id: "",
            request: { type: "confirm", prompt: "x", default_yes: true },
          }),
        ),
      ).resolves.toBe(
        JSON.stringify({
          type: "ui_response",
          request_id: "unknown",
          error: { code: "malformed_request" },
        }),
      );
    } finally {
      restore();
    }
    // Nothing was ever presented.
    expect(bar.isActive()).toBe(false);
  });

  test("returns a correlated timeout error and closes the ask", async () => {
    const { mount, bar } = makeBar();
    const callback = createUiRequestCallback(bar, 1);
    await expect(
      callback(
        JSON.stringify({
          type: "ui_request",
          request_id: "request-timeout",
          request: {
            type: "input",
            prompt: "Wait",
          },
        }),
      ),
    ).resolves.toBe(
      JSON.stringify({
        type: "ui_response",
        request_id: "request-timeout",
        error: { code: "timeout" },
      }),
    );
    expect(mount.children).toHaveLength(0);
  });
});
