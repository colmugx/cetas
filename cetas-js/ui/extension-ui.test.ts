import { describe, expect, test } from "bun:test";
import chalk from "chalk";
import { Container, type Component } from "@earendil-works/pi-tui";

import {
  UiRenderHost,
  UiRequestBar,
  createUiRequestCallback,
} from "./extension-ui.ts";

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
    expect(line).toContain("deepseek-v4-pro");
    expect(line).toContain("effort: high");
    expect(line).toContain("tok: 10↑ 2↓");
    // The first entry renders as a bare bold value and the title is dropped.
    expect(line).not.toContain("model:");
    expect(line).not.toContain("Status");
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

  test("rejects concurrent requests explicitly", async () => {
    const { tui, bar } = makeBar();
    const first = bar.request({
      type: "confirm",
      prompt: "Continue?",
      default_yes: true,
    });

    await expect(
      bar.request({
        type: "input",
        prompt: "Name",
      }),
    ).rejects.toThrow("concurrent UiRequest");

    tui.focused!.handleInput!("\u001b");
    await expect(first).resolves.toEqual({ type: "cancelled" });
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

  test("rejects malformed request events", async () => {
    const { bar } = makeBar();
    const callback = createUiRequestCallback(bar, 1_000);
    await expect(
      callback(
        JSON.stringify({
          type: "ui_request",
          request_id: "",
          request: { type: "confirm", prompt: "x" },
        }),
      ),
    ).rejects.toThrow("request_id must not be empty");
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
