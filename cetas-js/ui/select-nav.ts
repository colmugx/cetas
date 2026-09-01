import { matchesKey } from "@earendil-works/pi-tui";

// pi-tui's SelectList binds only the vertical arrows (tui.select.up/down).
// Translate the horizontal arrows onto them so pickers navigate the way their
// "←→/↑↓" footers read — the panel-level counterpart of the direct escape
// sequence matching in extension-ui's horizontal row.
export function translateSelectArrows(data: string): string {
  if (matchesKey(data, "left")) return "\u001b[A";
  if (matchesKey(data, "right")) return "\u001b[B";
  return data;
}
