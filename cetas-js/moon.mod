// cetas-js — bun-runtime host for cetas.
//
// Target: js (bun runtime; Node-compatible node:fs / node:crypto FFI).
// Filesystem access goes through posoco-ext-workspace (JsWorkspaceFs);
// credential persistence through posoco-ext-credentials.
// UI via pi-tui (driven from host.ts).
// Agent logic reuses cetas-core.

name = "colmugx/cetas-js"

version = "0.3.2"

readme = "README.mbt.md"

repository = ""

license = "Apache-2.0"

keywords = [ "cetas", "js", "bun", "pi-tui" ]

description = "Cetas JS host — bun runtime + pi-tui UI, reuses cetas-core for agent logic"

preferred_target = "js"

import {
  "colmugx/posoco@0.15.0",
  "colmugx/cetas-core@0.2.0",
  "colmugx/cetas-ext-forme@0.1.0",
  "colmugx/posoco-devkit@0.3.0",
  "colmugx/posoco-ext-bash@0.2.0",
  "colmugx/posoco-ext-context@0.2.0",
  "colmugx/posoco-ext-credentials@0.1.0",
  "colmugx/posoco-ext-edit@0.2.0",
  "colmugx/posoco-ext-fs-session@0.3.0",
  "colmugx/posoco-ext-glob@0.2.0",
  "colmugx/posoco-ext-goal@0.2.0",
  "colmugx/posoco-ext-grep@0.2.0",
  "colmugx/posoco-ext-herdr@0.1.0",
  "colmugx/posoco-ext-llm@0.2.0",
  "colmugx/posoco-ext-mcp@0.4.0",
  "colmugx/posoco-ext-oauth@0.1.0",
  "colmugx/posoco-ext-openai@0.1.0",
  "colmugx/posoco-ext-permission@0.2.0",
  "colmugx/posoco-ext-pi-adaptor@0.1.0",
  "colmugx/posoco-ext-plan@0.3.0",
  "colmugx/posoco-ext-ratelimit@0.3.0",
  "colmugx/posoco-ext-read@0.2.0",
  "colmugx/posoco-ext-skills@0.2.0",
  "colmugx/posoco-ext-stats@0.1.0",
  "colmugx/posoco-ext-statusbar@0.3.0",
  "colmugx/posoco-ext-webfetch@0.1.0",
  "colmugx/posoco-ext-workspace@0.1.0",
  "colmugx/posoco-ext-write@0.2.0",
  "colmugx/posoco-ext-zcode@0.1.0",
  "moonbitlang/async@0.21.2",
}
