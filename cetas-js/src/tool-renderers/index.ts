/**
 * index.ts — registerToolRenderer side-effects for hook-style renderers.
 *
 * The read/write/edit/glob/grep rows are driven by the declarative spec
 * table (specs.ts) and need no registration; only renderers with bespoke
 * behavior register here (bash: elapsed timer, ask_question: option list).
 *
 * Import this module once at host startup:
 *   import "./tool-renderers/index.ts";
 * After that, `pickToolRenderer(name)` returns the right renderer.
 */

import { registerToolRenderer } from "./registry.ts";
import { askQuestionRenderer } from "./askquestion.ts";
import { bashRenderer } from "./bash.ts";

let registered = false;

/** Idempotent: safe to call multiple times. */
export function registerBuiltinToolRenderers(): void {
  if (registered) return;
  registered = true;
  registerToolRenderer("ask_question", askQuestionRenderer);
  registerToolRenderer("bash", bashRenderer);
}

// Side-effect on import — covers the case where callers just `import
// "./tool-renderers/index"` without calling the registration function.
registerBuiltinToolRenderers();

export { pickToolRenderer, statusBullet, callBullet } from "./registry.ts";
export { TOOL_ROW_SPECS } from "./specs.ts";
export type {
  ToolRenderContext,
  ToolRenderer,
  ToolRenderResultOptions,
} from "./registry.ts";
export type { ArgSpec, ToolRowSpec } from "./specs.ts";
