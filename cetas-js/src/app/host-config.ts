import { homedir } from "node:os";

import type { CetasHostConfig } from "./types.ts";

/** Fields an entry point may override; everything else keeps the defaults. */
export interface CetasHostConfigOverrides {
  cwd?: string;
  home?: string;
  maxToolRounds?: number;
  permissionMode?: CetasHostConfig["permissionMode"];
  /**
   * Explicit sessions directory for hosts that choose their own layout; when
   * omitted the MoonBit config resolves the per-project bucket itself (see
   * `resolvedSessionsDir` for the resolved path).
   */
  sessionsDir?: string;
  /** Host /help note; see `CetasHostConfig.hostHelpNote`. */
  hostHelpNote?: string;
}

/**
 * Shared host-config assembly for the cetas-js entry points (host.ts,
 * smoke.ts): process working directory, user home, and permission posture.
 * The sessions layout is left to the MoonBit side unless explicitly set.
 */
export function buildCetasHostConfig(
  overrides: CetasHostConfigOverrides = {},
): CetasHostConfig {
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
    ...(overrides.sessionsDir === undefined
      ? {}
      : { sessionsDir: overrides.sessionsDir }),
    ...(overrides.hostHelpNote === undefined || overrides.hostHelpNote === ""
      ? {}
      : { hostHelpNote: overrides.hostHelpNote }),
  };
}
