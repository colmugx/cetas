/**
 * osc133.ts — OSC 133 prompt-marking helpers.
 *
 * Why: terminal shells and multiplexers (zsh / fish / tmux / wezterm) use
 * OSC 133 marks to identify prompt boundaries and command output. Marking
 * user input and assistant replies lets the user scroll-jump, copy, and
 * search within cetas output the same way they would in their shell.
 *
 * The exact sequences (per iTerm2 + FinalTerm spec):
 *   ESC ] 133 ; A BEL   — start of prompt
 *   ESC ] 133 ; B BEL   — start of command output (we use it as "end of input")
 *   ESC ] 133 ; C BEL   — end of command output (final marker)
 *   ESC ] 133 ; D ; <rc> BEL — exit code (we omit — no exit code concept here)
 *
 * We wrap the user message with A+B and the assistant message with A+C, so
 * the assistant's reply is treated as "command output" by scrollback tools.
 */

const BEL = "\x07";
const ESC = "\x1b";

export const OSC133_PROMPT_START = `${ESC}]133;A${BEL}`;
export const OSC133_PROMPT_END = `${ESC}]133;B${BEL}`;
export const OSC133_OUTPUT_END = `${ESC}]133;C${BEL}`;

/** Wrap rendered user-message lines with A..B marks. */
export function wrapUserLines(lines: string[]): string[] {
  if (lines.length === 0) return lines;
  const out = lines.slice();
  out[0] = OSC133_PROMPT_START + out[0];
  out[out.length - 1] = OSC133_PROMPT_END + out[out.length - 1];
  return out;
}

/** Wrap rendered assistant/tool-output lines with A..C marks. */
export function wrapAssistantLines(lines: string[]): string[] {
  if (lines.length === 0) return lines;
  const out = lines.slice();
  out[0] = OSC133_PROMPT_START + out[0];
  out[out.length - 1] = OSC133_OUTPUT_END + out[out.length - 1];
  return out;
}
