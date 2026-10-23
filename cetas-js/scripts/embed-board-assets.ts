// Embeds the built Board browser app into the Cetas Bun host.
// Run after rebuilding posoco-ext-board-web:
//   bun scripts/embed-board-assets.ts
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const dist = join(
  import.meta.dir,
  "..",
  "..",
  "extension",
  "posoco-ext-board-web",
  "dist",
);
const out = join(import.meta.dir, "..", "ui", "board-assets.generated.ts");

const html = readFileSync(join(dist, "index.html"), "utf8");
const js = readFileSync(join(dist, "index.js"), "utf8");
const css = readFileSync(join(dist, "board.css"), "utf8");

const header =
  "// Generated from posoco-ext-board-web/dist; do not edit.\n" +
  "// Run: bun scripts/embed-board-assets.ts\n";

writeFileSync(
  out,
  header +
    `export const BOARD_HTML = ${JSON.stringify(html)};\n` +
    `export const BOARD_JS = ${JSON.stringify(js)};\n` +
    `export const BOARD_CSS = ${JSON.stringify(css)};\n`,
);

console.log(
  `wrote ${out} (${js.length} JS bytes, ${css.length} CSS bytes)`,
);
