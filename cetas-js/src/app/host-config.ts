import { homedir } from "node:os";

import { projectSessionsDir } from "./session-id.ts";
import type { CetasHostConfig } from "./types.ts";

/** Fields an entry point may override; everything else keeps the defaults. */
export interface CetasHostConfigOverrides {
  cwd?: string;
  home?: string;
  maxToolRounds?: number;
  permissionMode?: CetasHostConfig["permissionMode"];
  /** Derived per-project layout under `<home>/.cetas/sessions` unless set. */
  sessionsDir?: string;
  /** Host /help note; see `CetasHostConfig.hostHelpNote`. */
  hostHelpNote?: string;
}

/**
 * Shared host-config assembly for the cetas-js entry points (host.ts,
 * smoke.ts): process working directory, user home, and pi's per-project
 * sessions layout.
 */
export function buildCetasHostConfig(
  overrides: CetasHostConfigOverrides = {},
): CetasHostConfig & { sessionsDir: string } {
  const cwd = overrides.cwd ?? process.cwd();
  const home = overrides.home ?? homedir();
  return {
    cwd,
    // 0 = unbounded: the loop ends when the model stops calling tools or the
    // user aborts; the kernel budget is opt-in safety.
    maxToolRounds: overrides.maxToolRounds ?? 0,
    home,
    ...(overrides.permissionMode === undefined
      ? {}
      : { permissionMode: overrides.permissionMode }),
    sessionsDir: overrides.sessionsDir ?? projectSessionsDir(home, cwd),
    ...(overrides.hostHelpNote === undefined || overrides.hostHelpNote === ""
      ? {}
      : { hostHelpNote: overrides.hostHelpNote }),
  };
}
