name = "colmugx/cetas-run"

version = "0.7.0"

readme = "README.mbt.md"

repository = "https://github.com/colmugx/cetas"

license = "Apache-2.0"

keywords = [ "cetas", "runner", "stdio", "one-shot", "agent" ]

description = "Cetas run host — runs exactly one cetas user turn per invocation (argv task or one stdin line) with a /dev/tty interactive bypass"

supported_targets = "+native +wasm"

import {
  "colmugx/posoco@0.20.4",
  "colmugx/cetas-core@0.2.0",
  "posoco/devkit@0.4.1",
  "posoco/ext-herdr@0.1.0",
  "posoco/ext-llm@0.2.0",
  "colmugx/posoco-ext-permission@0.2.0",
  "colmugx/posoco-ext-workspace@0.1.0",
  "moonbitlang/async@0.22.4",
  "posoco/ext-oauth@0.1.0",
  "colmugx/posoco-ext-credentials@0.1.0",
  // recipe-deps:begin
  // recipe-deps:end
}
