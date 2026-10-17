import { getNativeClipboard } from "@earendil-works/pi-tui";

type ClipboardWriter = { setText(text: string): void | Promise<void> };
type TerminalWriter = { isTTY?: boolean; write(text: string): unknown };

export type ClipboardResult = "native" | "terminal" | "unavailable";

export interface ClipboardOptions {
  native?: ClipboardWriter | null;
  terminal?: TerminalWriter;
  preferTerminal?: boolean;
}

/**
 * Send a copy to the clipboard on the user's terminal, including when the
 * application runs inside a terminal multiplexer or on a remote host.
 *
 * A successful OSC 52 write only means the request was sent: terminal
 * clipboard policies may still reject it without acknowledging the request.
 */
export async function copyTextToClipboard(
  text: string,
  options: ClipboardOptions = {},
): Promise<ClipboardResult> {
  let native: ClipboardWriter | null;
  try {
    native = options.native === undefined ? getNativeClipboard() ?? null : options.native;
  } catch {
    native = null;
  }

  const terminal = options.terminal ?? process.stdout;
  const preferTerminal = options.preferTerminal ?? Boolean(process.env.HERDR_ENV);
  const copyNative = async (): Promise<boolean> => {
    if (!native?.setText) return false;
    try {
      await native.setText(text);
      return true;
    } catch {
      return false;
    }
  };
  const copyTerminal = (): boolean => {
    if (!terminal.isTTY) return false;
    try {
      terminal.write(`\x1b]52;c;${Buffer.from(text, "utf8").toString("base64")}\x07`);
      return true;
    } catch {
      return false;
    }
  };

  if (preferTerminal) {
    if (copyTerminal()) return "terminal";
    return await copyNative() ? "native" : "unavailable";
  }
  if (await copyNative()) return "native";
  return copyTerminal() ? "terminal" : "unavailable";
}
