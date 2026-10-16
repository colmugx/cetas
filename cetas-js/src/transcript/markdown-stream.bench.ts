/**
 * Reproducible Gate 4 render-only benchmark:
 *   cd cetas-js && bun --preload ./moonbit-preload.ts src/transcript/markdown-stream.bench.ts
 * Runs real pi-tui Markdown against the same incremental streaming input.
 * The benchmark does not assert a particular speedup; syntax may trigger
 * an intentional exact-render fallback.
 */
import { performance } from "node:perf_hooks";
import { Markdown } from "@earendil-works/pi-tui";
import { markdownTheme } from "../../ui/theme.ts";
import { IncrementalMarkdown } from "./markdown-stream.ts";

const paragraphs = Array.from({ length: 100 }, (_, index) =>
  `This is stable paragraph ${index}. ` +
  "A long description of the current implementation in clear ordinary prose. ".repeat(10),
);
const source = paragraphs.join("\n\n");
const samples = Array.from({ length: 200 }, (_, i) => source.slice(0, Math.round(source.length * (i + 1) / 200)));

function measure(name: string, build: () => { setText(v: string): void; render(w: number): string[] }) {
  const component = build();
  const start = performance.now();
  let rows = 0;
  for (const sample of samples) {
    component.setText(sample);
    rows += component.render(100).length;
  }
  return { name, elapsedMs: Math.round((performance.now() - start) * 10) / 10, rows };
}

const baseline = measure("pi-tui Markdown", () => new Markdown("", 1, 0, markdownTheme));
const incremental = measure("cetas IncrementalMarkdown", () => new IncrementalMarkdown("", 1, 0, markdownTheme));
console.log(JSON.stringify({
  inputCharacters: source.length,
  updates: samples.length,
  width: 100,
  baseline,
  incremental,
  note: "Warm up and repeat across 8/40/80/120-column widths for performance decisions.",
}, null, 2));
