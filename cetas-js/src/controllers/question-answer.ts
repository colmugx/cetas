/**
 * question-answer.ts — the host's answer shape for one parked
 * `notify_user` question (`/answer`, `@qN` input). Mirrors the extension's
 * `answer_async` payload: exactly one field is meaningful, chosen by the
 * question kind.
 */

/** Reply to one parked question. */
export type QuestionAnswerResponse =
  | { readonly text: string }
  | { readonly confirm: boolean }
  | { readonly index: number };

/** Render one answer response as the wire JSON the bridge expects. */
export function answerResponseJson(response: QuestionAnswerResponse): string {
  return JSON.stringify(response);
}

/**
 * Parse the `/answer` argument form: `@q3 <text>`, `q3 <text>`, or
 * `question-3 <text>`. Returns the canonical id and the reply text, or
 * `undefined` when the input does not address a question.
 */
export function parseAnswerArgument(
  raw: string,
): { readonly questionId: string; readonly text: string } | undefined {
  const trimmed = raw.trim();
  if (trimmed.length === 0) return undefined;
  const match = /^(?:@q|q|question-)(\d+)(?:\s+([\s\S]*))?$/.exec(trimmed);
  if (match === null) return undefined;
  return {
    questionId: `question-${match[1]}`,
    text: (match[2] ?? "").trim(),
  };
}

/**
 * Parse a leading `@qN` in a normal prompt: the human's shorthand for
 * "this is my answer to question N". Only a leading token counts and the
 * digit run must be followed by end-of-input or whitespace, so `@query`
 * or `@q12abc` stay ordinary `@path` mentions.
 */
export function parseQuestionAnswerPrefix(
  prompt: string,
): { readonly questionId: string; readonly text: string } | undefined {
  const match = /^@q(\d+)(?:[ \t]+([\s\S]*))?$/.exec(prompt.trim());
  if (match === null) return undefined;
  return {
    questionId: `question-${match[1]}`,
    text: (match[2] ?? "").trim(),
  };
}

/**
 * Turn free-typed text into the answer shape the question kind expects:
 * `confirm` understands yes/no words, `select` matches an option label or
 * a 0-based index, `input` passes through. Text that cannot be mapped
 * yields `undefined` so the caller can ask again instead of sending the
 * wrong answer kind (the extension would refuse it anyway).
 */
export function answerFromText(
  kind: "input" | "confirm" | "select",
  text: string,
  options: readonly string[],
): QuestionAnswerResponse | undefined {
  const value = text.trim();
  if (kind === "confirm") {
    const word = value.toLowerCase();
    if (["y", "yes", "true", "ok", "sure"].includes(word)) return { confirm: true };
    if (["n", "no", "false", "nope"].includes(word)) return { confirm: false };
    return undefined;
  }
  if (kind === "select") {
    const exact = options.findIndex((option) => option === value);
    if (exact >= 0) return { index: exact };
    const folded = options.findIndex(
      (option) => option.toLowerCase() === value.toLowerCase(),
    );
    if (folded >= 0) return { index: folded };
    if (/^\d+$/.test(value)) {
      const index = Number(value);
      return index < options.length ? { index } : undefined;
    }
    return undefined;
  }
  return value.length > 0 ? { text: value } : undefined;
}
