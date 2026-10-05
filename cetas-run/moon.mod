name = "colmugx/cetas-run"

version = "0.7.0"

readme = "README.mbt.md"

repository = "https://github.com/colmugx/cetas"

license = "Apache-2.0"

keywords = [ "cetas", "runner", "stdio", "one-shot", "agent" ]

description = "Cetas run host — runs exactly one cetas user turn per invocation (argv task or one stdin line) with a /dev/tty interactive bypass"

supported_targets = "+native +wasm"

import {
  "colmugx/posoco@0.21.0",
  "colmugx/cetas-core@0.2.0",
  "posoco/devkit@0.4.1",
  "posoco/ext-llm@0.2.0",
  "colmugx/posoco-ext-permission@0.2.0",
  "colmugx/posoco-ext-workspace@0.1.0",
  "posoco/ext-oauth@0.1.0",
  "colmugx/posoco-ext-credentials@0.1.0",
  "moonbitlang/async@0.22.4",
  // recipe-deps:begin
  "colmugx/cetas-ext-forme@0.1.0",
  "colmugx/posoco-ext-read@0.2.0",
  "colmugx/posoco-ext-write@0.2.0",
  "colmugx/posoco-ext-edit@0.2.0",
  "colmugx/posoco-ext-glob@0.2.0",
  "colmugx/posoco-ext-grep@0.2.0",
  "colmugx/posoco-ext-astgrep@0.1.0",
  "colmugx/posoco-ext-webfetch@0.1.0",
  "colmugx/posoco-ext-bash@0.2.0",
  "colmugx/posoco-ext-ps1@0.1.0",
  "colmugx/posoco-ext-skills@0.2.0",
  "colmugx/posoco-ext-askquestion@0.1.0",
  "colmugx/posoco-ext-handoff@0.1.0",
  "colmugx/posoco-ext-lazytools@0.1.0",
  "posoco/ext-herdr@0.1.0",
  // recipe-deps:end
}
