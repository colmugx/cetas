/**
 * OAuth progress surface for cetas-js.
 *
 * OAuth providers report only provider-neutral interaction messages through
 * the Observer custom-event channel. This adapter keeps those messages
 * visible while `/login` is in flight; it does not inspect credentials or
 * provider endpoints and never executes a URL on the user's behalf.
 */

import {
  Markdown,
  Text,
  matchesKey,
  type Component,
  type OverlayHandle,
} from "@earendil-works/pi-tui";

import type { CetasEvent } from "../src/events.ts";
import { markdownTheme, theme } from "./theme.ts";

export type OAuthNotification =
  | { type: "url"; url: string }
  | { type: "device_code"; verificationUri: string; userCode: string }
  | { type: "progress"; message: string };

export interface OAuthOverlayTui {
  showOverlay(component: Component, options?: {
    width?: number | `${number}%`;
    maxHeight?: number | `${number}%`;
    anchor?: "center" | "top-left" | "top-right" | "bottom-left" | "bottom-right" | "top-center" | "bottom-center" | "left-center" | "right-center";
    margin?: number;
  }): OverlayHandle;
  requestRender(): void;
}

function record(value: unknown, path: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${path} must be an object`);
  }
  return value as Record<string, unknown>;
}

function optionalString(value: unknown, path: string): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "string") throw new Error(`${path} must be a string`);
  return value;
}

/** Remove control characters before data reaches a terminal text component. */
function visible(value: string, path: string): string {
  const clean = value.replace(/[\u0000-\u0008\u000B-\u001F\u007F]/g, "");
  if (clean.length === 0) throw new Error(`${path} must not be empty`);
  return clean;
}

/**
 * Decode the stable OAuth interaction vocabulary from a custom event.
 * Unknown custom events return null and remain available to the normal event
 * router, so extension-specific telemetry is never hidden by this adapter.
 */
export function parseOAuthNotification(
  source: string,
  label: string,
  data: unknown,
): OAuthNotification | null {
  const oauthSource = source.toLowerCase().includes("oauth") || source.toLowerCase().includes("auth");
  if (!oauthSource) return null;
  const value = typeof data === "string" ? data : data === undefined ? undefined : record(data, "oauth custom data");
  switch (label) {
    case "auth_url":
    case "url": {
      const url = typeof value === "string"
        ? value
        : optionalString(value?.url ?? value?.auth_url, "oauth custom data.url");
      if (url === undefined) throw new Error("oauth auth_url notification is missing url");
      return { type: "url", url: visible(url, "oauth auth_url") };
    }
    case "device_code": {
      if (typeof value === "string" || value === undefined) {
        throw new Error("oauth device_code notification must contain verification_uri and user_code");
      }
      const verificationUri = optionalString(
        value.verification_uri ?? value.verification_url ?? value.url,
        "oauth custom data.verification_uri",
      );
      const userCode = optionalString(
        value.user_code ?? value.code,
        "oauth custom data.user_code",
      );
      if (verificationUri === undefined || userCode === undefined) {
        throw new Error("oauth device_code notification is missing verification_uri or user_code");
      }
      return {
        type: "device_code",
        verificationUri: visible(verificationUri, "oauth verification_uri"),
        userCode: visible(userCode, "oauth user_code"),
      };
    }
    case "progress":
    case "status": {
      const message = typeof value === "string"
        ? value
        : optionalString(value?.message ?? value?.progress ?? value?.value, "oauth custom data.message");
      if (message === undefined) throw new Error("oauth progress notification is missing message");
      return { type: "progress", message: visible(message, "oauth progress") };
    }
    default:
      return null;
  }
}

class OAuthPanel implements Component {
  focused = false;
  private readonly title: Text;
  private readonly body: Markdown;
  private provider: string;
  private status = "Waiting for provider…";
  private url: string | undefined;
  private verificationUri: string | undefined;
  private userCode: string | undefined;
  private result: string | undefined;

  constructor(
    provider: string,
    private readonly onClose: () => void,
  ) {
    this.provider = provider;
    this.title = new Text(theme.brandBold(`OAuth login · ${provider}`), 1, 1);
    this.body = new Markdown("", 1, 0, markdownTheme);
    this.refresh();
  }

  setProvider(provider: string): void {
    this.provider = provider;
    this.refresh();
  }

  apply(notification: OAuthNotification): void {
    switch (notification.type) {
      case "url":
        this.url = notification.url;
        this.status = "Open the authorization URL in your browser.";
        break;
      case "device_code":
        this.verificationUri = notification.verificationUri;
        this.userCode = notification.userCode;
        this.status = "Enter the device code, then wait for authorization.";
        break;
      case "progress":
        this.status = notification.message;
        break;
    }
    this.result = undefined;
    this.refresh();
  }

  setResult(message: string, isError: boolean): void {
    this.result = visible(message, "oauth result");
    this.status = isError ? "OAuth login failed." : "OAuth login finished.";
    this.refresh();
  }

  render(width: number): string[] {
    return [...this.title.render(width), ...this.body.render(width)];
  }

  handleInput(data: string): void {
    // Escape/Enter close the view and OAuthOverlay propagates cancellation to
    // the application token; the provider observes it at its polling boundary.
    // Use matchesKey so the close gesture works on every terminal encoding of
    // these keys (Kitty protocol, xterm modifyOtherKeys, numpad enter); a bare
    // \u001b comparison silently fails on modern terminals and leaves users
    // unable to cancel despite the "Press Esc" hint.
    if (matchesKey(data, "escape") || matchesKey(data, "enter") || data === "q") {
      this.onClose();
    }
  }

  invalidate(): void {
    this.title.invalidate();
    this.body.invalidate();
  }

  private refresh(): void {
    const lines = [
      `**${this.status}**`,
      "",
      this.url === undefined
        ? ""
        : `Authorization URL: [Open authorization URL](${this.url})`,
      this.verificationUri === undefined
        ? ""
        : `Verification URL: [Open verification URL](${this.verificationUri})`,
      this.userCode === undefined ? "" : `Device code: **${this.userCode}**`,
      this.result === undefined ? "" : `\n${this.result}`,
      "",
      "Press Enter or Esc to close this view.",
    ].filter((line) => line.length > 0);
    this.body.setText(lines.join("\n"));
    this.body.invalidate();
  }
}

/** Keeps one OAuth activity overlay mounted during a login command. */
export class OAuthOverlay {
  private handle?: OverlayHandle;
  private panel?: OAuthPanel;

  constructor(
    private readonly tui: OAuthOverlayTui,
    private readonly onCancel?: () => void,
  ) {}

  get isActive(): boolean {
    return this.handle !== undefined;
  }

  show(provider: string): void {
    if (this.handle !== undefined) {
      this.panel?.setProvider(provider);
      this.tui.requestRender();
      return;
    }
    const panel = new OAuthPanel(provider, () => this.hide());
    this.panel = panel;
    this.handle = this.tui.showOverlay(panel, {
      width: "78%",
      maxHeight: "70%",
      anchor: "center",
      margin: 1,
    });
    this.tui.requestRender();
  }

  notify(event: Extract<CetasEvent, { type: "custom" }>): boolean {
    const notification = parseOAuthNotification(event.source, event.label, event.data);
    if (notification === null) return false;
    if (this.panel === undefined) this.show("provider");
    this.panel!.apply(notification);
    this.tui.requestRender();
    return true;
  }

  result(message: string, isError: boolean): void {
    if (this.panel === undefined) this.show("provider");
    this.panel!.setResult(message, isError);
    this.tui.requestRender();
  }

  hide(): void {
    this.onCancel?.();
    const handle = this.handle;
    this.handle = undefined;
    this.panel = undefined;
    handle?.hide();
    this.tui.requestRender();
  }
}
