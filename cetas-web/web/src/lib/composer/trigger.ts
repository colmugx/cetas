export type TriggerKind = "command" | "file" | "skill";

export type ActiveTrigger = {
  kind: TriggerKind;
  query: string;
  start: number;
  end: number;
};

/**
 * The trigger active at `caret`, or null.
 *
 * - `@path` / `$name` are word-bounded: the span ends at the first
 *   whitespace before the caret.
 * - `/command` spans spaces (cetas-js `spanSpaces`): the span starts at
 *   the last `/` that sits at line start or after whitespace, so
 *   `/model high` keeps completing arguments — but `https://x` never
 *   triggers, because its slash is not at a boundary.
 */
export function detectTrigger(text: string, caret: number): ActiveTrigger | null {
  const at = Math.min(caret, text.length);

  // @ and $: word-bounded token ending at the caret.
  let wordStart = at;
  while (wordStart > 0 && !/\s/.test(text[wordStart - 1])) wordStart -= 1;
  const word = text.slice(wordStart, at);
  if (word.startsWith("@")) {
    return { kind: "file", query: word.slice(1), start: wordStart, end: at };
  }
  if (word.startsWith("$")) {
    return { kind: "skill", query: word.slice(1), start: wordStart, end: at };
  }

  // /: boundary-anchored slash, spanning spaces up to the caret.
  for (let i = at - 1; i >= 0; i -= 1) {
    const ch = text[i];
    if (ch === "\n") return null;
    if (ch === "/" && (i === 0 || /\s/.test(text[i - 1]))) {
      return { kind: "command", query: text.slice(i + 1, at), start: i, end: at };
    }
  }
  return null;
}

/**
 * Replace the trigger span with `insert` and return the new text plus the
 * caret position right after the inserted text.
 */
export function applyInsert(
  text: string,
  trigger: ActiveTrigger,
  insert: string,
): { text: string; caret: number } {
  const before = text.slice(0, trigger.start);
  const after = text.slice(trigger.end);
  const caret = trigger.start + insert.length;
  return { text: before + insert + after, caret };
}
