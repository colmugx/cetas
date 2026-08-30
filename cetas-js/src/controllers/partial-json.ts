/**
 * partial-json.ts — best-effort parser for truncated JSON object buffers.
 *
 * The tool-args streamer accumulates raw `arguments_delta` fragments into one
 * string that is almost never valid JSON until the call completes (stream cut
 * mid-string is the common case). This module scans such a buffer and returns
 * everything that can be displayed:
 *
 *   - every complete `"key": value` pair whose value is a fully formed JSON
 *     value (string / number / true / false / null / nested object / array)
 *   - PLUS, when the buffer ends inside a string value, that key mapped to
 *     the partially-unescaped text so far — escape sequences decode only
 *     when complete: `\n` `\t` `\r` `\b` `\f` `\"` `\\` `\/` fully, `\uXXXX`
 *     only with all 4 hex digits; a trailing lone `\` or partial `\u12`
 *     contributes nothing rather than leaking a backslash
 *
 * Incomplete numbers/literals and unfinished nested containers contribute no
 * value for their key (a half-received `12` could still become `123`), but
 * pairs parsed before them are kept. Malformed input never throws — the
 * scan simply stops and whatever was collected so far is returned.
 */

/** Outcome of scanning one JSON value at a cursor position. */
type Scan<T> =
  | { kind: "complete"; value: T; next: number }
  /** Input exhausted mid-value; `partial` carries displayable in-progress
   *  string text when the truncated value was a string. */
  | { kind: "incomplete"; partial?: T };

const ESCAPES: Record<string, string> = {
  n: "\n",
  t: "\t",
  r: "\r",
  b: "\b",
  f: "\f",
  '"': '"',
  "\\": "\\",
  "/": "/",
};

function skipWs(s: string, i: number): number {
  while (i < s.length && /\s/.test(s[i])) i++;
  return i;
}

function scanString(s: string, start: number): Scan<string> {
  // Caller guarantees s[start] === '"'.
  let out = "";
  let i = start + 1;
  while (i < s.length) {
    const c = s[i];
    if (c === '"') return { kind: "complete", value: out, next: i + 1 };
    if (c === "\\") {
      const marker = s[i + 1];
      if (marker === undefined) {
        // Lone trailing backslash — drop it.
        return { kind: "incomplete", partial: out };
      }
      if (marker === "u") {
        const hex = s.slice(i + 2, i + 6);
        if (!/^[0-9a-fA-F]{4}$/.test(hex)) {
          // Partial \u12 at end-of-input or malformed \u — drop the escape.
          return { kind: "incomplete", partial: out };
        }
        out += String.fromCharCode(parseInt(hex, 16));
        i += 6;
        continue;
      }
      const decoded = ESCAPES[marker];
      if (decoded === undefined) {
        // Unknown escape — malformed; stop before emitting anything wrong.
        return { kind: "incomplete", partial: out };
      }
      out += decoded;
      i += 2;
      continue;
    }
    out += c;
    i++;
  }
  return { kind: "incomplete", partial: out };
}

function scanNumber(s: string, start: number): Scan<number> {
  let i = start;
  while (i < s.length && /[-+0-9.eE]/.test(s[i])) i++;
  const run = s.slice(start, i);
  if (!/^-?\d+(\.\d+)?([eE][+-]?\d+)?$/.test(run)) {
    // Digits may still be arriving ("-"/"1e+"/"1.") — incomplete, not invalid.
    return { kind: "incomplete" };
  }
  const c = s[i];
  if (c === undefined) return { kind: "incomplete" };
  if (c === "," || c === "}" || c === "]") {
    return { kind: "complete", value: Number(run), next: i };
  }
  if (/\s/.test(c)) {
    const j = skipWs(s, i);
    const d = s[j];
    if (d === undefined) return { kind: "incomplete" };
    if (d === "," || d === "}" || d === "]") {
      return { kind: "complete", value: Number(run), next: i };
    }
  }
  return { kind: "incomplete" };
}

function scanLiteral(
  s: string,
  start: number,
  word: string,
  value: boolean | null,
): Scan<boolean | null> {
  if (s.startsWith(word, start)) {
    return { kind: "complete", value, next: start + word.length };
  }
  // Partial keyword ("tru") or garbage both stop the scan without a value.
  return { kind: "incomplete" };
}

function scanArray(s: string, start: number): Scan<unknown[]> {
  const items: unknown[] = [];
  let i = skipWs(s, start + 1);
  if (s[i] === "]") return { kind: "complete", value: items, next: i + 1 };
  for (;;) {
    if (i >= s.length) return { kind: "incomplete", partial: items };
    const elem = scanValue(s, i);
    if (elem.kind !== "complete") {
      if (elem.kind === "incomplete" && typeof elem.partial === "string") {
        items.push(elem.partial);
      }
      return { kind: "incomplete", partial: items };
    }
    items.push(elem.value);
    i = skipWs(s, elem.next);
    if (i >= s.length) return { kind: "incomplete", partial: items };
    if (s[i] === ",") {
      i = skipWs(s, i + 1);
      continue;
    }
    if (s[i] === "]") return { kind: "complete", value: items, next: i + 1 };
    return { kind: "incomplete", partial: items };
  }
}

function scanObject(s: string, start: number): Scan<Record<string, unknown>> {
  const obj: Record<string, unknown> = {};
  let i = skipWs(s, start + 1);
  if (s[i] === "}") return { kind: "complete", value: obj, next: i + 1 };
  for (;;) {
    if (i >= s.length || s[i] !== '"') return { kind: "incomplete", partial: obj };
    const key = scanString(s, i);
    if (key.kind !== "complete") return { kind: "incomplete", partial: obj };
    i = skipWs(s, key.next);
    if (i >= s.length || s[i] !== ":") return { kind: "incomplete", partial: obj };
    i = skipWs(s, i + 1);
    const val = scanValue(s, i);
    if (val.kind !== "complete") {
      if (val.kind === "incomplete" && val.partial !== undefined) {
        obj[key.value] = val.partial;
      }
      return { kind: "incomplete", partial: obj };
    }
    obj[key.value] = val.value;
    i = skipWs(s, val.next);
    if (i >= s.length) return { kind: "incomplete", partial: obj };
    if (s[i] === ",") {
      i = skipWs(s, i + 1);
      continue;
    }
    if (s[i] === "}") return { kind: "complete", value: obj, next: i + 1 };
    return { kind: "incomplete", partial: obj };
  }
}

function scanValue(s: string, i: number): Scan<unknown> {
  i = skipWs(s, i);
  if (i >= s.length) return { kind: "incomplete" };
  switch (s[i]) {
    case '"':
      return scanString(s, i);
    case "{":
      return scanObject(s, i);
    case "[":
      return scanArray(s, i);
    case "t":
      return scanLiteral(s, i, "true", true);
    case "f":
      return scanLiteral(s, i, "false", false);
    case "n":
      return scanLiteral(s, i, "null", null);
    default:
      return scanNumber(s, i);
  }
}

/**
 * Parse an accumulated (usually truncated) arguments buffer into a display
 * record. See the module doc for exactly what survives truncation.
 */
export function parsePartialJsonObject(raw: string): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  let i = skipWs(raw, 0);
  if (raw[i] !== "{") return out;
  const scanned = scanObject(raw, i);
  if (scanned.kind === "complete") return scanned.value as Record<string, unknown>;
  return scanned.partial ?? out;
}
