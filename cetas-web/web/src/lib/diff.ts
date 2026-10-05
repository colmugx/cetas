/**
 * Synthesize a line-level diff from an edit's old/new text by trimming the
 * common prefix and suffix. Good enough for model-sized edits and instant.
 */
export type DiffLine = { sign: " " | "-" | "+"; text: string };

export function synthesizeDiff(
  oldText: string | undefined,
  newText: string | undefined,
): DiffLine[] {
  const before = (oldText ?? "").split("\n");
  const after = (newText ?? "").split("\n");
  let prefix = 0;
  while (
    prefix < before.length &&
    prefix < after.length &&
    before[prefix] === after[prefix]
  ) {
    prefix++;
  }
  let suffix = 0;
  while (
    suffix < before.length - prefix &&
    suffix < after.length - prefix &&
    before[before.length - 1 - suffix] === after[after.length - 1 - suffix]
  ) {
    suffix++;
  }
  const removed = before.slice(prefix, before.length - suffix);
  const added = after.slice(prefix, after.length - suffix);
  const contextBefore = before.slice(Math.max(0, prefix - 3), prefix);
  const contextAfter = before.slice(
    before.length - suffix,
    before.length - suffix + 3,
  );
  return [
    ...contextBefore.map((line) => ({ sign: " " as const, text: line })),
    ...removed.map((line) => ({ sign: "-" as const, text: line })),
    ...added.map((line) => ({ sign: "+" as const, text: line })),
    ...contextAfter.map((line) => ({ sign: " " as const, text: line })),
  ];
}
