import {
  Container,
  Input,
  Loader,
  Markdown,
  SelectList,
  Text,
  type Component,
  type OverlayHandle,
  type OverlayOptions,
  type SelectListTheme,
  type TUI,
} from "@earendil-works/pi-tui";

import { markdownTheme, theme } from "./theme.ts";

export type UiSlot = "status" | "notice" | "widget";

export type UiBody =
  | { type: "text"; text: string }
  | { type: "lines"; lines: string[] }
  | { type: "key_value"; entries: Array<{ key: string; value: string }> }
  | { type: "progress"; current: number; label?: string }
  | { type: "markdown"; text: string };

export interface UiRender {
  slot: UiSlot;
  key: string;
  title: string;
  body: UiBody;
  ttl_ms?: number;
}

export type UiRequest =
  | { type: "input"; prompt: string; placeholder?: string }
  | { type: "confirm"; prompt: string; default_yes: boolean }
  | {
      type: "select";
      title: string;
      options: string[];
      default_index?: number;
    };

export type UiResponse =
  | { type: "text"; text: string }
  | { type: "yes" }
  | { type: "no" }
  | { type: "selected"; index: number }
  | { type: "cancelled" };

type UnknownRecord = Record<string, unknown>;

function requireRecord(value: unknown, path: string): UnknownRecord {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${path} must be an object`);
  }
  return value as UnknownRecord;
}

function requireString(value: unknown, path: string): string {
  if (typeof value !== "string") {
    throw new Error(`${path} must be a string`);
  }
  return value;
}

function optionalString(value: unknown, path: string): string | undefined {
  if (value === undefined) return undefined;
  return requireString(value, path);
}

function parseUiRequest(value: unknown): UiRequest {
  const request = requireRecord(value, "ui_request.request");
  const type = requireString(request.type, "ui_request.request.type");
  switch (type) {
    case "input":
      return {
        type,
        prompt: requireString(request.prompt, "ui_request.request.prompt"),
        placeholder: optionalString(
          request.placeholder,
          "ui_request.request.placeholder",
        ),
      };
    case "confirm":
      if (typeof request.default_yes !== "boolean") {
        throw new Error("ui_request.request.default_yes must be a boolean");
      }
      return {
        type,
        prompt: requireString(request.prompt, "ui_request.request.prompt"),
        default_yes: request.default_yes,
      };
    case "select": {
      if (
        !Array.isArray(request.options) ||
        !request.options.every((option) => typeof option === "string")
      ) {
        throw new Error("ui_request.request.options must be a string array");
      }
      const defaultIndex = request.default_index;
      if (
        defaultIndex !== undefined &&
        (!Number.isInteger(defaultIndex) || (defaultIndex as number) < 0)
      ) {
        throw new Error(
          "ui_request.request.default_index must be a non-negative integer",
        );
      }
      return {
        type,
        title: requireString(request.title, "ui_request.request.title"),
        options: request.options,
        default_index: defaultIndex as number | undefined,
      };
    }
    default:
      throw new Error(`unsupported UiRequest type: ${type}`);
  }
}

function parseUiBody(value: unknown): UiBody {
  const body = requireRecord(value, "ui_render.render.body");
  const type = requireString(body.type, "ui_render.render.body.type");
  switch (type) {
    case "text":
    case "markdown":
      return {
        type,
        text: requireString(body.text, "ui_render.render.body.text"),
      };
    case "lines":
      if (
        !Array.isArray(body.lines) ||
        !body.lines.every((line) => typeof line === "string")
      ) {
        throw new Error("ui_render.render.body.lines must be a string array");
      }
      return { type, lines: body.lines };
    case "key_value":
      if (!Array.isArray(body.entries)) {
        throw new Error("ui_render.render.body.entries must be an array");
      }
      return {
        type,
        entries: body.entries.map((entry, index) => {
          const record = requireRecord(
            entry,
            `ui_render.render.body.entries[${index}]`,
          );
          return {
            key: requireString(
              record.key,
              `ui_render.render.body.entries[${index}].key`,
            ),
            value: requireString(
              record.value,
              `ui_render.render.body.entries[${index}].value`,
            ),
          };
        }),
      };
    case "progress":
      if (typeof body.current !== "number" || !Number.isFinite(body.current)) {
        throw new Error("ui_render.render.body.current must be a finite number");
      }
      return {
        type,
        current: body.current,
        label: optionalString(body.label, "ui_render.render.body.label"),
      };
    default:
      throw new Error(`unsupported UiBody type: ${type}`);
  }
}

export function parseUiRender(value: unknown): UiRender {
  const render = requireRecord(value, "ui_render.render");
  const slot = requireString(render.slot, "ui_render.render.slot");
  if (slot !== "status" && slot !== "notice" && slot !== "widget") {
    throw new Error(`unsupported UiSlot: ${slot}`);
  }
  const ttl = render.ttl_ms;
  if (
    ttl !== undefined &&
    (!Number.isSafeInteger(ttl) || (ttl as number) <= 0)
  ) {
    throw new Error("ui_render.render.ttl_ms must be a positive integer");
  }
  return {
    slot,
    key: requireString(render.key, "ui_render.render.key"),
    title: requireString(render.title, "ui_render.render.title"),
    body: parseUiBody(render.body),
    ttl_ms: ttl as number | undefined,
  };
}

interface OverlayTui {
  showOverlay(component: Component, options?: OverlayOptions): OverlayHandle;
  requestRender(): void;
}

interface RenderMounts {
  status: Container;
  notice: Container;
  widget: Container;
}

interface MountedRender {
  component: Component;
  container: Container;
  dispose(): void;
  ttl?: ReturnType<typeof setTimeout>;
}

function assertRender(intent: UiRender): void {
  if (intent.key.length === 0) {
    throw new Error("UiRender.key must not be empty");
  }
  if (intent.ttl_ms !== undefined && intent.ttl_ms <= 0) {
    throw new Error(`UiRender.ttl_ms must be positive, got ${intent.ttl_ms}`);
  }
}

function formatKeyValue(entries: Array<{ key: string; value: string }>): string {
  const keyWidth = entries.reduce((width, entry) => Math.max(width, entry.key.length), 0);
  return entries
    .map((entry) => `${theme.muted(entry.key.padEnd(keyWidth))}  ${entry.value}`)
    .join("\n");
}

function renderBody(
  tui: TUI,
  title: string,
  body: UiBody,
): { component: Component; dispose(): void } {
  switch (body.type) {
    case "text":
      return {
        component: new Text(`${theme.bold(title)}\n${body.text}`, 1, 0),
        dispose() {},
      };
    case "lines":
      return {
        component: new Text(
          `${theme.bold(title)}\n${body.lines.map((line) => `• ${line}`).join("\n")}`,
          1,
          0,
        ),
        dispose() {},
      };
    case "key_value":
      return {
        component: new Text(
          `${theme.bold(title)}\n${formatKeyValue(body.entries)}`,
          1,
          0,
        ),
        dispose() {},
      };
    case "markdown":
      return {
        component: new Markdown(
          `${title.length > 0 ? `**${title}**\n\n` : ""}${body.text}`,
          1,
          0,
          markdownTheme,
        ),
        dispose() {},
      };
    case "progress": {
      if (!Number.isFinite(body.current) || body.current < 0 || body.current > 1) {
        throw new Error(
          `UiBody.progress.current must be within [0, 1], got ${body.current}`,
        );
      }
      const percent = Math.round(body.current * 100);
      const message = [title, body.label, `${percent}%`].filter(Boolean).join(" · ");
      const loader = new Loader(
        tui,
        theme.accent,
        theme.muted,
        message,
        body.current === 1 ? { frames: [] } : undefined,
      );
      if (body.current < 1) {
        loader.start();
      }
      return {
        component: loader,
        dispose: () => loader.stop(),
      };
    }
  }
}

/**
 * Owns keyed ext-rendered components. Re-rendering the same key replaces the
 * previous component and disposes any running loader/timer.
 */
export class UiRenderHost {
  private readonly rendered = new Map<string, MountedRender>();

  constructor(
    private readonly tui: TUI,
    private readonly mounts: RenderMounts,
  ) {}

  render(intent: UiRender): void {
    assertRender(intent);
    this.remove(intent.key);

    const renderedBody = renderBody(this.tui, intent.title, intent.body);
    const container = this.mounts[intent.slot];
    const mounted: MountedRender = {
      component: renderedBody.component,
      container,
      dispose: renderedBody.dispose,
    };
    container.addChild(mounted.component);
    this.rendered.set(intent.key, mounted);

    if (intent.ttl_ms !== undefined) {
      mounted.ttl = setTimeout(() => {
        this.remove(intent.key);
        this.tui.requestRender();
      }, intent.ttl_ms);
    }
    this.tui.requestRender();
  }

  remove(key: string): void {
    const mounted = this.rendered.get(key);
    if (!mounted) return;
    if (mounted.ttl !== undefined) {
      clearTimeout(mounted.ttl);
    }
    mounted.dispose();
    mounted.container.removeChild(mounted.component);
    this.rendered.delete(key);
  }

  dispose(): void {
    for (const key of [...this.rendered.keys()]) {
      this.remove(key);
    }
    this.tui.requestRender();
  }
}

/** Build the strict one-way callback consumed by JsUiPort.render. */
export function createUiRenderCallback(
  host: UiRenderHost,
): (eventJson: string) => void {
  return (eventJson) => {
    const event = requireRecord(JSON.parse(eventJson), "ui_render");
    if (event.type !== "ui_render") {
      throw new Error(`expected ui_render event, got ${String(event.type)}`);
    }
    host.render(parseUiRender(event.render));
  };
}

class RequestOverlay implements Component {
  focused = false;

  constructor(
    private readonly title: Text,
    private readonly control: Component,
  ) {}

  render(width: number): string[] {
    if ("focused" in this.control) {
      (this.control as Component & { focused: boolean }).focused = this.focused;
    }
    return [...this.title.render(width), ...this.control.render(width)];
  }

  handleInput(data: string): void {
    this.control.handleInput?.(data);
  }

  invalidate(): void {
    this.title.invalidate();
    this.control.invalidate();
  }
}

const selectTheme: SelectListTheme = {
  selectedPrefix: theme.accent,
  selectedText: theme.accent,
  description: theme.muted,
  scrollInfo: theme.muted,
  noMatch: theme.error,
};

/**
 * Presents one strict modal request at a time. A second concurrent request is
 * rejected because stacking interactive extension prompts is ambiguous.
 */
export class UiRequestOverlay {
  private active = false;
  private cancelActive?: () => void;

  constructor(private readonly tui: OverlayTui) {}

  isActive(): boolean {
    return this.active;
  }

  cancel(): void {
    const cancelActive = this.cancelActive;
    this.cancelActive = undefined;
    cancelActive?.();
  }

  async request(request: UiRequest): Promise<UiResponse> {
    if (this.active) {
      throw new Error("concurrent UiRequest is not supported");
    }
    this.active = true;
    try {
      return await this.open(request);
    } finally {
      this.active = false;
      this.cancelActive = undefined;
    }
  }

  private open(request: UiRequest): Promise<UiResponse> {
    return new Promise((resolve) => {
      let handle: OverlayHandle;
      let settled = false;
      const settle = (response: UiResponse) => {
        if (settled) {
          throw new Error("UiRequest overlay settled more than once");
        }
        settled = true;
        this.cancelActive = undefined;
        handle.hide();
        resolve(response);
      };

      let panel: RequestOverlay;
      switch (request.type) {
        case "input": {
          const input = new Input();
          input.onSubmit = (value) => settle({ type: "text", text: value });
          input.onEscape = () => settle({ type: "cancelled" });
          const hint =
            request.placeholder === undefined
              ? request.prompt
              : `${request.prompt}\n${theme.muted(request.placeholder)}`;
          panel = new RequestOverlay(new Text(hint, 1, 1), input);
          break;
        }
        case "confirm": {
          const list = new SelectList(
            [
              { value: "yes", label: "Yes" },
              { value: "no", label: "No" },
            ],
            2,
            selectTheme,
          );
          list.setSelectedIndex(request.default_yes ? 0 : 1);
          list.onSelect = (item) => settle({ type: item.value as "yes" | "no" });
          list.onCancel = () => settle({ type: "cancelled" });
          panel = new RequestOverlay(new Text(request.prompt, 1, 1), list);
          break;
        }
        case "select": {
          if (request.options.length === 0) {
            throw new Error("UiRequest.select.options must not be empty");
          }
          if (
            request.default_index !== undefined &&
            (request.default_index < 0 ||
              request.default_index >= request.options.length)
          ) {
            throw new Error(
              `UiRequest.select.default_index out of bounds: ${request.default_index}`,
            );
          }
          const list = new SelectList(
            request.options.map((option, index) => ({
              value: String(index),
              label: option,
            })),
            Math.min(8, request.options.length),
            selectTheme,
          );
          list.setSelectedIndex(request.default_index ?? 0);
          list.onSelect = (item) =>
            settle({ type: "selected", index: Number(item.value) });
          list.onCancel = () => settle({ type: "cancelled" });
          panel = new RequestOverlay(new Text(request.title, 1, 1), list);
          break;
        }
      }

      handle = this.tui.showOverlay(panel, {
        width: "70%",
        maxHeight: "70%",
        anchor: "center",
        margin: 1,
      });
      this.cancelActive = () => settle({ type: "cancelled" });
    });
  }
}

/** Build the exact Promise callback consumed by JsUiPort. */
export function createUiRequestCallback(
  overlay: UiRequestOverlay,
  timeoutMs: number,
): (eventJson: string) => Promise<string> {
  if (!Number.isInteger(timeoutMs) || timeoutMs <= 0) {
    throw new Error("UI request timeout must be a positive integer");
  }
  return async (eventJson) => {
    const event = requireRecord(JSON.parse(eventJson), "ui_request");
    if (event.type !== "ui_request") {
      throw new Error(`expected ui_request event, got ${String(event.type)}`);
    }
    const requestId = requireString(event.request_id, "ui_request.request_id");
    if (requestId.length === 0) {
      throw new Error("ui_request.request_id must not be empty");
    }
    const request = parseUiRequest(event.request);
    let timeout: ReturnType<typeof setTimeout> | undefined;
    const timed = new Promise<"timeout">((resolve) => {
      timeout = setTimeout(() => {
        resolve("timeout");
        overlay.cancel();
      }, timeoutMs);
    });
    try {
      const outcome = await Promise.race([overlay.request(request), timed]);
      if (outcome === "timeout") {
        return JSON.stringify({
          type: "ui_response",
          request_id: requestId,
          error: { code: "timeout" },
        });
      }
      return JSON.stringify({
        type: "ui_response",
        request_id: requestId,
        response: outcome,
      });
    } finally {
      if (timeout !== undefined) clearTimeout(timeout);
    }
  };
}
