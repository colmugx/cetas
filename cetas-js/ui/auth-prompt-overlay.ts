/**
 * Provider-neutral authentication prompts for cetas-js.
 *
 * Provider extensions describe a secret or a selection; this module only
 * renders the request with pi-tui and returns the opaque response. Secret
 * input is masked at render time and is never copied into a label, event, or
 * diagnostic string.
 */

import {
  Input,
  SelectList,
  Text,
  type Component,
  type OverlayHandle,
  type SelectItem,
  type SelectListTheme,
} from "@earendil-works/pi-tui";

import { theme } from "./theme.ts";

export interface AuthPromptOption {
  id: string;
  label: string;
  description?: string;
}

export type AuthPromptRequest =
  | { type: "secret"; message: string }
  | { type: "select"; message: string; options: readonly AuthPromptOption[] };

export interface AuthPromptTui {
  showOverlay(component: Component, options?: {
    width?: number | `${number}%`;
    maxHeight?: number | `${number}%`;
    anchor?: "center" | "top-left" | "top-right" | "bottom-left" | "bottom-right" | "top-center" | "bottom-center" | "left-center" | "right-center";
    margin?: number;
  }): OverlayHandle;
  requestRender(): void;
}

const selectTheme: SelectListTheme = {
  selectedPrefix: (value) => theme.accent(value),
  selectedText: (value) => theme.accent(value),
  description: (value) => theme.muted(value),
  scrollInfo: (value) => theme.muted(value),
  noMatch: (value) => theme.error(value),
};

function record(value: unknown, path: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${path} must be an object`);
  }
  return value as Record<string, unknown>;
}

function string(value: unknown, path: string): string {
  if (typeof value !== "string") throw new Error(`${path} must be a string`);
  return value;
}

function visible(value: string, path: string): string {
  const clean = value.replace(/[\u0000-\u0008\u000B-\u001F\u007F]/g, "");
  if (clean.trim().length === 0) throw new Error(`${path} must not be empty`);
  return clean;
}

/** Parse the stable wire shape emitted by the host-side auth interaction. */
export function parseAuthPromptRequest(raw: unknown): AuthPromptRequest {
  const value = record(raw, "auth prompt");
  const request = value.request === undefined ? value : record(value.request, "auth prompt.request");
  const type = string(request.type, "auth prompt.type");
  const message = visible(string(request.message, "auth prompt.message"), "auth prompt.message");
  if (type === "secret") return { type, message };
  if (type !== "select") throw new Error(`auth prompt.type is unsupported: ${type}`);
  const rawOptions = request.options;
  if (!Array.isArray(rawOptions) || rawOptions.length === 0) {
    throw new Error("auth prompt.select options must be a non-empty array");
  }
  const options = rawOptions.map((rawOption, index) => {
    const option = record(rawOption, `auth prompt.options[${index}]`);
    const id = visible(string(option.id, `auth prompt.options[${index}].id`), `auth prompt.options[${index}].id`);
    const label = visible(string(option.label, `auth prompt.options[${index}].label`), `auth prompt.options[${index}].label`);
    const description = option.description === undefined || option.description === null
      ? undefined
      : visible(string(option.description, `auth prompt.options[${index}].description`), `auth prompt.options[${index}].description`);
    return { id, label, ...(description === undefined ? {} : { description }) };
  });
  return { type, message, options };
}

class SelectPromptPanel implements Component {
  focused = false;

  constructor(
    private readonly title: Text,
    private readonly list: SelectList,
  ) {}

  render(width: number): string[] {
    return [...this.title.render(width), ...this.list.render(width)];
  }

  handleInput(data: string): void {
    this.list.handleInput(data);
  }

  invalidate(): void {
    this.title.invalidate();
    this.list.invalidate();
  }
}

/** Secret input uses pi-tui's editing semantics but renders only a mask. */
class SecretPromptPanel implements Component {
  focused = false;
  private readonly input = new Input();

  constructor(
    private readonly title: Text,
    private readonly onSubmit: (value: string) => void,
    private readonly onCancel: () => void,
  ) {
    this.input.onSubmit = (value) => this.onSubmit(value);
    this.input.onEscape = this.onCancel;
  }

  render(width: number): string[] {
    const value = this.input.getValue();
    // Do not render the value itself, even transiently. A fixed-width bullet
    // per code point preserves useful feedback without revealing characters.
    const masked = "•".repeat([...value].length);
    const body = new Text(`> ${masked}`, 1, 0);
    return [...this.title.render(width), ...body.render(width)];
  }

  handleInput(data: string): void {
    this.input.handleInput(data);
    this.invalidate();
  }

  invalidate(): void {
    this.title.invalidate();
  }
}

/** A single in-flight provider-neutral authentication prompt. */
export class AuthPromptOverlay {
  private handle?: OverlayHandle;
  private settle?: (value: string) => void;
  private reject?: (reason: unknown) => void;

  constructor(private readonly tui: AuthPromptTui) {}

  get isActive(): boolean {
    return this.handle !== undefined;
  }

  request(request: AuthPromptRequest): Promise<string> {
    if (this.handle !== undefined) {
      return Promise.reject(new Error("another authentication prompt is active"));
    }
    return new Promise<string>((resolve, reject) => {
      this.settle = resolve;
      this.reject = reject;
      const complete = (value: string) => this.finish(value);
      const cancel = () => this.cancel();
      let panel: Component;
      if (request.type === "secret") {
        panel = new SecretPromptPanel(
          new Text(theme.brandBold(request.message), 1, 1),
          complete,
          cancel,
        );
      } else {
        const items: SelectItem[] = request.options.map((option) => ({
          value: option.id,
          label: option.label,
          ...(option.description === undefined ? {} : { description: option.description }),
        }));
        const list = new SelectList(items, Math.min(8, items.length), selectTheme);
        const selectPanel = new SelectPromptPanel(
          new Text(theme.brandBold(request.message), 1, 1),
          list,
        );
        list.onSelect = (item) => complete(item.value);
        list.onCancel = cancel;
        panel = selectPanel;
      }
      this.handle = this.tui.showOverlay(panel, {
        width: "72%",
        maxHeight: "62%",
        anchor: "center",
        margin: 1,
      });
      this.tui.requestRender();
    });
  }

  cancel(): void {
    if (this.handle === undefined) return;
    const reject = this.reject;
    this.clear();
    reject?.(new Error("authentication prompt cancelled"));
  }

  hide(): void {
    this.cancel();
  }

  private finish(value: string): void {
    if (this.handle === undefined) return;
    if (value.length === 0) {
      this.cancel();
      return;
    }
    const resolve = this.settle;
    this.clear();
    resolve?.(value);
  }

  private clear(): void {
    const handle = this.handle;
    this.handle = undefined;
    this.settle = undefined;
    this.reject = undefined;
    handle?.hide();
    this.tui.requestRender();
  }
}
