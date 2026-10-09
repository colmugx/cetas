name = "colmugx/cetas-native"

version = "0.7.0"

readme = "README.md"

repository = "https://github.com/colmugx/cetas"

license = "Apache-2.0"

keywords = [ "cetas", "tui", "native", "ratatui" ]

description = "Native Cetas TUI host backed by Ratatui"

preferred_target = "native"

supported_targets = "native"

import {
  "colmugx/posoco@0.22.0",
  "colmugx/cetas-core@0.2.0",
  "colmugx/posoco-ext-permission@0.2.0",
  "colmugx/posoco-ext-workspace@0.1.0",
  "colmugx/posoco-ext-fs-session@0.4.0",
  "colmugx/posoco-ext-context@0.2.0",
  "posoco/ext-llm@0.2.0",
  "moonbitlang/async@0.22.4",
  "moonbitlang/x@0.5.5",
  "posoco/devkit@0.4.1",
  "posoco/ext-oauth@0.1.0",
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
  "colmugx/posoco-ext-stats@0.1.0",
  "colmugx/posoco-ext-statusbar@0.3.0",
  "colmugx/posoco-ext-subagent@0.1.3",
  "colmugx/posoco-ext-kind@0.1.0",
  "colmugx/posoco-kit-subagent@0.1.1",
  // recipe-deps:end
}

options(
  "--moonbit-unstable-prebuild": "build.js",
)
