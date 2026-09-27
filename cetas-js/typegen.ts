// Generate TypeScript declarations for the MoonBit imports consumed by cetas-js.
// Keep this separate from build.ts: typechecking should not depend on producing
// a release binary as a side effect.
import { moonbit } from "bun-plugin-moonbit";

const result = await Bun.build({
  entrypoints: ["host.ts"],
  // Bun target matches the runtime host; the browser default rejects pi-tui's
  // Node builtin imports.
  target: "bun",
  plugins: [
    moonbit({
      root: import.meta.dir,
      mode: "release",
      dts: {
        out: "gen/mbt.d.ts",
        externPolicy: {
          JsCallback: "(eventJson: string) => void",
          JsUiRenderCallback: "(eventJson: string) => void",
          JsUiRequestCallback: "(requestJson: string) => Promise<string>",
          JsCancelCheck: "() => boolean",
        },
      },
    }),
  ],
});

if (!result.success) {
  console.error("✗ dts gen/mbt.d.ts");
  for (const log of result.logs) console.error(log);
  throw new Error("Bun.build failed while generating MoonBit declarations");
}

console.log("✓ dts gen/mbt.d.ts");
