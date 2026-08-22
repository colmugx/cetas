/**
 * index.ts — registerToolRenderer side-effects for all built-in tools.
 *
 * Import this module once at host startup:
 *   import "./tool-renderers/index.ts";
 * After that, `pickToolRenderer(name)` returns the right renderer.
 */

import { registerToolRenderer } from "./registry.ts";
import { askQuestionRenderer } from "./askquestion.ts";
import { bashRenderer } from "./bash.ts";
import { editRenderer } from "./edit.ts";
import { globRenderer } from "./glob.ts";
import { grepRenderer } from "./grep.ts";
import { readRenderer } from "./read.ts";
import { writeRenderer } from "./write.ts";

let registered = false;

/** Idempotent: safe to call multiple times. */
export function registerBuiltinToolRenderers(): void {
  if (registered) return;
  registered = true;
  registerToolRenderer("ask_question", askQuestionRenderer);
  registerToolRenderer("bash", bashRenderer);
  registerToolRenderer("read", readRenderer);
  registerToolRenderer("write", writeRenderer);
  registerToolRenderer("edit", editRenderer);
  registerToolRenderer("grep", grepRenderer);
  registerToolRenderer("glob", globRenderer);
}

// Side-effect on import — covers the case where callers just `import
// "./tool-renderers/index"` without calling the registration function.
registerBuiltinToolRenderers();

export { pickToolRenderer, statusBullet, callBullet } from "./registry.ts";
export type {
  ToolRenderContext,
  ToolRenderer,
  ToolRenderResultOptions,
} from "./registry.ts";
