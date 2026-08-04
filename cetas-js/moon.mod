// cetas-js — bun-runtime host for cetas.
//
// Target: js (bun runtime, NOT node).
// All IO via Bun globals (Bun.file / Bun.write / Bun.spawn / fetch).
// UI via pi-tui (driven from host.ts).
// Agent logic reuses cetas-core.

name = "colmugx/cetas-js"

version = "0.1.0"

readme = "README.mbt.md"

repository = ""

license = "Apache-2.0"

keywords = [ "cetas", "js", "bun", "pi-tui" ]

description = "Cetas JS host — bun runtime + pi-tui UI, reuses cetas-core for agent logic"

import {
  "colmugx/posoco@0.7.3",
  "colmugx/cetas-core@0.1.0",
  "colmugx/posoco-devkit@0.1.0",
  "colmugx/posoco-ext-fs-session@0.1.0",
  "colmugx/posoco-ext-llm@0.1.0",
  "colmugx/posoco-ext-oauth@0.1.0",
  "moonbitlang/async@0.20.3",
}
