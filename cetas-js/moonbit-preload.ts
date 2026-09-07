import { moonbit } from "bun-plugin-moonbit";

// bun-plugin-moonbit's runtime resolver is synchronous by Bun contract, so
// the Moon build must finish before Bun.plugin registration — hence prepare().
// Published 0.1.0-beta.0 lacks the lifecycle API; with it, mbt: imports fail
// at runtime instead. See round-1-plan.md open questions.
const watch = process.argv.some((arg) => arg === "--hot" || arg === "--watch");

const plugin = moonbit({
  root: import.meta.dir,
  mode: process.env.MOONBIT_MODE === "debug" ? "debug" : "release",
  watch,
});

if (typeof plugin.prepare === "function") {
  await plugin.prepare();
}
Bun.plugin(plugin);
