import {
  Container,
  getKeybindings,
  Input,
  Loader,
  Markdown,
  matchesKey,
  Text,
  type Component,
  type TUI,
  truncateToWidth,
  visibleWidth,
} from "@earendil-works/pi-tui";

import { markdownTheme, roleStyle, theme } from "./theme.ts";

export type UiSlot = "status" | "notice" | "widget";

export type UiBody =
  | { type: "text"; text: string }
  | { type: "lines"; lines: string[] }
  | { type: "key_value"; entries: Array<{ key: string; value: string }> }
  | {
      type: "entries";
      entries: Array<{ key: string; value: string; color?: string }>;
    }
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

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** Bound free-form bridge payloads for console logs (~200 chars). */
function boundedJson(value: string, max = 200): string {
  return value.length <= max ? value : `${value.slice(0, max)}…`;
}

/** Bounded error text — engine SyntaxErrors embed raw input snippets. */
function boundedReason(error: unknown): string {
  return boundedJson(errorMessage(error), 120);
}

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
    case "entries":
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
            color: optionalString(
              record.color,
              `ui_render.render.body.entries[${index}].color`,
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

interface RenderMounts {
  status: Container;
  notice: Container;
  widget: Container;
}

/**
 * Route one `slot:key` render to a dedicated mount instead of the slot's
 * shared container. `format: "line"` renders a key_value or entries body as
 * a single status-bar line of muted `key: value` segments joined by ` | `
 * instead of the default titled multi-line block.
 */
export interface UiKeyRoute {
  mount: Container;
  format?: "line";
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

/**
 * Status values that carry an absolute UTC timestamp (ISO-8601 `Z` form —
 * the devkit status convention, e.g. the ratelimit reset announcement) are
 * the one thing the host localizes: MoonBit publishers stay timezone-free,
 * and the user's wall clock is a host concern. Rendered as local
 * `yyyy-mm-dd hh:mm:ss`; every other value passes through untouched.
 */
const UTC_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;

export function formatStatusValue(value: string): string {
  if (!UTC_TIMESTAMP.test(value)) return value;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  const pad = (n: number) => String(n).padStart(2, "0");
  return (
    `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
    ` ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`
  );
}

function formatKeyValue(entries: Array<{ key: string; value: string }>): string {
  const keyWidth = entries.reduce((width, entry) => Math.max(width, entry.key.length), 0);
  return entries
    .map((entry) => `${theme.muted(entry.key.padEnd(keyWidth))}  ${entry.value}`)
    .join("\n");
}

/**
 * Render keyed entries as one status-bar line: every segment is a muted
 * `key:` label plus its value, values styled by their color role, segments
 * joined by a muted ` | `. A role-less first value keeps the legacy bold
 * treatment; later role-less values stay plain. The host decides line
 * placement through key routes; this is only a shape.
 */
function renderKeyValueLine(
  entries: Array<{ key: string; value: string; color?: string }>,
): { component: Component; dispose(): void } {
  const segments = entries.map((entry, index) => {
    const value =
      entry.color !== undefined
        ? roleStyle(entry.color)(formatStatusValue(entry.value))
        : index === 0
          ? theme.bold(formatStatusValue(entry.value))
          : formatStatusValue(entry.value);
    return `${theme.muted(`${entry.key}:`)} ${value}`;
  });
  const line = segments.join(theme.muted(" | "));
  return { component: new Text(line, 1, 0), dispose() {} };
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
    case "entries":
      // Non-line route: degrade to one `key: value` line per entry. Color
      // roles are the line renderer's concern, not the block renderer's.
      return {
        component: new Text(
          `${theme.bold(title)}\n${body.entries
            .map((entry) => `${entry.key}: ${formatStatusValue(entry.value)}`)
            .join("\n")}`,
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
 * Owns keyed ext-rendered components, keyed by `slot:key` so the same key in
 * different slots stays independent. Re-rendering a `slot:key` replaces the
 * previous component and disposes any running loader/timer.
 */
export class UiRenderHost {
  private readonly rendered = new Map<string, MountedRender>();
  private readonly keyRoutes: Readonly<Record<string, UiKeyRoute>>;

  constructor(
    private readonly tui: TUI,
    private readonly mounts: RenderMounts,
    keyRoutes: Readonly<Record<string, UiKeyRoute>> = {},
  ) {
    this.keyRoutes = keyRoutes;
  }

  render(intent: UiRender): void {
    assertRender(intent);
    const slotKey = `${intent.slot}:${intent.key}`;
    this.unmount(slotKey);

    const route = this.keyRoutes[slotKey];
    const body = intent.body;
    const renderedBody =
      route?.format === "line" && (body.type === "key_value" || body.type === "entries")
        ? renderKeyValueLine(body.entries)
        : renderBody(this.tui, intent.title, body);
    const container = route?.mount ?? this.mounts[intent.slot];
    const mounted: MountedRender = {
      component: renderedBody.component,
      container,
      dispose: renderedBody.dispose,
    };
    container.addChild(mounted.component);
    this.rendered.set(slotKey, mounted);

    if (intent.ttl_ms !== undefined) {
      mounted.ttl = setTimeout(() => {
        this.unmount(slotKey);
        this.tui.requestRender();
      }, intent.ttl_ms);
    }
    this.tui.requestRender();
  }

  remove(slot: UiSlot, key: string): void {
    this.unmount(`${slot}:${key}`);
  }

  private unmount(slotKey: string): void {
    const mounted = this.rendered.get(slotKey);
    if (!mounted) return;
    if (mounted.ttl !== undefined) {
      clearTimeout(mounted.ttl);
    }
    mounted.dispose();
    mounted.container.removeChild(mounted.component);
    this.rendered.delete(slotKey);
  }

  dispose(): void {
    for (const slotKey of [...this.rendered.keys()]) {
      this.unmount(slotKey);
    }
    this.tui.requestRender();
  }
}

/**
 * Build the one-way callback consumed by JsUiPort.render. It crosses the
 * MoonBit FFI, where a throw kills the whole turn, so any failure — bad
 * json, wrong type tag, malformed render body — is logged (bounded) and the
 * render dropped: a lost status widget beats a dead turn.
 */
export function createUiRenderCallback(
  host: UiRenderHost,
): (eventJson: string) => void {
  return (eventJson) => {
    try {
      const event = requireRecord(JSON.parse(eventJson), "ui_render");
      if (event.type !== "ui_render") {
        throw new Error(`expected ui_render event, got ${String(event.type)}`);
      }
      host.render(parseUiRender(event.render));
    } catch (error: unknown) {
      console.warn(
        `cetas: dropped ui_render (${boundedReason(error)}): ${boundedJson(eventJson)}`,
      );
    }
  };
}

/** Options shown at once before the ask panel starts scrolling. */
const MAX_VISIBLE_OPTIONS = 8;

/**
 * One inline ask panel: the request's title lines, then either an option
 * row (confirm/select) or a text input. Buttons lay out horizontally along
 * the bottom and fall back to a stacked list when the row cannot fit the
 * terminal width. The focused button renders as a background block, not an
 * arrow prefix.
 */
class AskPanel implements Component {
  focused = false;
  private readonly titleLines: string[];
  private readonly placeholderLine?: string;
  private readonly options: ReadonlyArray<{
    label: string;
    response: UiResponse;
  }>;
  private readonly input?: Input;
  private selectedIndex = 0;
  private settled = false;
  /** Width of the most recent render; decides the layout, hence the arrow axis. */
  private lastWidth = 0;

  constructor(
    request: UiRequest,
    private readonly onSettle: (response: UiResponse) => void,
  ) {
    switch (request.type) {
      case "confirm":
        this.titleLines = request.prompt.split("\n");
        this.options = [
          { label: "Yes", response: { type: "yes" } },
          { label: "No", response: { type: "no" } },
        ];
        this.selectedIndex = request.default_yes ? 0 : 1;
        break;
      case "select":
        if (
          request.default_index !== undefined &&
          (request.default_index < 0 ||
            request.default_index >= request.options.length)
        ) {
          throw new Error(
            `UiRequest.select.default_index out of bounds: ${request.default_index}`,
          );
        }
        this.titleLines = request.title.split("\n");
        this.options = request.options.map((option, index) => ({
          label: option,
          response: { type: "selected", index },
        }));
        this.selectedIndex = request.default_index ?? 0;
        break;
      case "input":
        this.titleLines = request.prompt.split("\n");
        this.placeholderLine = request.placeholder;
        this.options = [];
        this.input = new Input();
        this.input.onSubmit = (value) => this.settle({ type: "text", text: value });
        this.input.onEscape = () => this.settle({ type: "cancelled" });
        break;
    }
  }

  settle(response: UiResponse): void {
    if (this.settled) {
      throw new Error("UiRequest panel settled more than once");
    }
    this.settled = true;
    this.onSettle(response);
  }

  render(width: number): string[] {
    this.lastWidth = width;
    // First title line is the question; the remaining lines are the detail
    // (e.g. the permission ask's arguments preview).
    const [firstTitle, ...restTitles] = this.titleLines;
    const lines: string[] = [];
    if (firstTitle !== undefined && firstTitle.length > 0) {
      lines.push(theme.bold(truncateToWidth(firstTitle, width)));
    }
    for (const line of restTitles) lines.push(theme.muted(truncateToWidth(line, width)));
    if (this.input !== undefined) {
      // The TUI focuses this panel, not the Input; forward the flag so the
      // caret renders (same passthrough the old overlay panel used).
      const input = this.input as Input & { focused?: boolean };
      if (typeof input.focused === "boolean") input.focused = this.focused;
      if (this.placeholderLine !== undefined) {
        lines.push(theme.muted(truncateToWidth(this.placeholderLine, width)));
      }
      lines.push(...this.input.render(width));
      lines.push(theme.muted(" ⏎ submit · esc cancel"));
      return lines;
    }
    const buttonRow = this.renderButtonRow(width);
    if (buttonRow !== undefined) {
      lines.push(buttonRow);
    } else {
      // Stacked fallback for option sets too wide for one row: the
      // selected option keeps the full-width background block.
      const [start, end] = this.visibleRange();
      for (let i = start; i < end; i++) {
        const option = this.options[i]!;
        if (i === this.selectedIndex) {
          const label = ` ${option.label}`;
          const pad = " ".repeat(Math.max(0, width - visibleWidth(label)));
          lines.push(theme.selection(label + pad));
        } else {
          lines.push(theme.muted(option.label));
        }
      }
      if (this.options.length > MAX_VISIBLE_OPTIONS) {
        lines.push(theme.muted(` (${this.selectedIndex + 1}/${this.options.length})`));
      }
    }
    // The footer names the axis that actually drives the current layout.
    lines.push(theme.muted(
      buttonRow !== undefined
        ? " ←→ choose · ⏎ confirm · esc cancel"
        : " ↑↓ choose · ⏎ confirm · esc cancel",
    ));
    return lines;
  }

  handleInput(data: string): void {
    if (this.input !== undefined) {
      this.input.handleInput?.(data);
      return;
    }
    const kb = getKeybindings();
    // The navigation axis follows the layout, never both: the horizontal
    // button row moves with left/right only, the stacked fallback with
    // up/down only. Left/right are not in pi-tui's select actions; matchesKey
    // covers every terminal encoding of those arrows.
    const horizontal = this.renderButtonRow(this.lastWidth) !== undefined;
    const back = horizontal
      ? matchesKey(data, "left")
      : kb.matches(data, "tui.select.up");
    const forward = horizontal
      ? matchesKey(data, "right")
      : kb.matches(data, "tui.select.down");
    if (back) {
      this.selectedIndex =
        this.selectedIndex === 0 ? this.options.length - 1 : this.selectedIndex - 1;
    } else if (forward) {
      this.selectedIndex =
        this.selectedIndex === this.options.length - 1 ? 0 : this.selectedIndex + 1;
    } else if (kb.matches(data, "tui.select.confirm")) {
      this.settle(this.options[this.selectedIndex]!.response);
    } else if (kb.matches(data, "tui.select.cancel")) {
      this.settle({ type: "cancelled" });
    }
  }

  invalidate(): void {
    this.input?.invalidate();
  }

  // One row carrying every button, or undefined when the row cannot fit
  // `width` (the caller falls back to the stacked list). The selected
  // button is the background block; unselected buttons stay plain.
  private renderButtonRow(width: number): string | undefined {
    const row = this.options
      .map((option) => ` ${option.label} `)
      .join(" ");
    if (visibleWidth(row) > width) {
      return undefined;
    }
    return this.options
      .map((option, index) =>
        index === this.selectedIndex
          ? theme.selection(` ${option.label} `)
          : theme.muted(` ${option.label} `),
      )
      .join(" ");
  }

  private visibleRange(): [number, number] {
    if (this.options.length <= MAX_VISIBLE_OPTIONS) {
      return [0, this.options.length];
    }
    let start = Math.max(0, this.selectedIndex - Math.floor(MAX_VISIBLE_OPTIONS / 2));
    const end = Math.min(this.options.length, start + MAX_VISIBLE_OPTIONS);
    start = Math.max(0, end - MAX_VISIBLE_OPTIONS);
    return [start, end];
  }
}

interface AskTui {
  setFocus(component: Component | null): void;
  requestRender(): void;
}

/**
 * Presents one strict ask at a time, inline directly above the editor —
 * not as a centered modal. The panel takes keyboard focus while active;
 * `restoreFocus` runs after the panel settles.
 *
 * One ask at a time; a newer ask withdraws the older. Presenting while an
 * ask is active auto-settles the previous one as `{type:"cancelled"}` (the
 * existing cancel path) before the new panel mounts — the old reject-on-
 * concurrent behavior surfaced as an opaque bridge failure on the MoonBit
 * side.
 */
export class UiRequestBar {
  private active = false;
  private cancelActive?: () => void;
  /** Identifies the request allowed to reset bar state in its finally. */
  private epoch = 0;

  constructor(
    private readonly tui: AskTui,
    private readonly mount: Container,
    private readonly restoreFocus: () => void,
  ) {}

  isActive(): boolean {
    return this.active;
  }

  cancel(): void {
    const cancelActive = this.cancelActive;
    this.cancelActive = undefined;
    cancelActive?.();
  }

  async request(request: UiRequest): Promise<UiResponse> {
    if (this.active) this.cancel();
    this.active = true;
    const epoch = ++this.epoch;
    try {
      return await this.open(request);
    } finally {
      // A superseded request must not clear the newer one's state: its
      // continuation resumes only after the new ask already mounted.
      if (epoch === this.epoch) {
        this.active = false;
        this.cancelActive = undefined;
      }
    }
  }

  private open(request: UiRequest): Promise<UiResponse> {
    return new Promise((resolve) => {
      // Defense in depth: an empty select cannot be presented. Resolve as
      // cancelled instead of throwing — a throw here rejects the host
      // callback and surfaces as an opaque "ui request failed" upstream.
      if (request.type === "select" && request.options.length === 0) {
        resolve({ type: "cancelled" });
        return;
      }
      // AskPanel's constructor throws for an out-of-bounds default_index;
      // inside the Promise executor that rejects the ask, same contract as
      // the old overlay.
      const panel = new AskPanel(request, (response) => {
        this.cancelActive = undefined;
        this.mount.removeChild(panel);
        this.restoreFocus();
        this.tui.requestRender();
        resolve(response);
      });
      this.mount.addChild(panel);
      this.tui.setFocus(panel);
      this.tui.requestRender();
      this.cancelActive = () => panel.settle({ type: "cancelled" });
    });
  }
}

/**
 * Build the exact Promise callback consumed by JsUiPort. The callback must
 * never reject across the FFI: malformed request bytes (bad json, wrong
 * type tag, unparsable request payload, unpresentable ask) degrade to a
 * correlated ui_response error instead of an opaque bridge failure.
 */
export function createUiRequestCallback(
  bar: UiRequestBar,
  timeoutMs: number,
): (eventJson: string) => Promise<string> {
  if (!Number.isInteger(timeoutMs) || timeoutMs <= 0) {
    throw new Error("UI request timeout must be a positive integer");
  }
  return async (eventJson) => {
    // "unknown" until a usable request_id is recovered from the bytes.
    let requestId = "unknown";
    try {
      const event = requireRecord(JSON.parse(eventJson), "ui_request");
      if (event.type !== "ui_request") {
        throw new Error(`expected ui_request event, got ${String(event.type)}`);
      }
      const parsedRequestId = requireString(event.request_id, "ui_request.request_id");
      if (parsedRequestId.length === 0) {
        throw new Error("ui_request.request_id must not be empty");
      }
      requestId = parsedRequestId;
      const request = parseUiRequest(event.request);
      let timeout: ReturnType<typeof setTimeout> | undefined;
      const timed = new Promise<"timeout">((resolve) => {
        timeout = setTimeout(() => {
          resolve("timeout");
          bar.cancel();
        }, timeoutMs);
      });
      try {
        const outcome = await Promise.race([bar.request(request), timed]);
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
    } catch (error: unknown) {
      console.warn(
        `cetas: rejected ui_request (${boundedReason(error)}): ${boundedJson(eventJson)}`,
      );
      return JSON.stringify({
        type: "ui_response",
        request_id: requestId,
        error: { code: "malformed_request" },
      });
    }
  };
}
