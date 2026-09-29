import { moonbit } from "bun-plugin-moonbit";

// The runtime resolver is synchronous, so finish the Moon build before
// Bun.plugin registration when the plugin exposes the prepare lifecycle.
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
