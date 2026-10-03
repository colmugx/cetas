name = "colmugx/cetas-native"

version = "0.0.1"

readme = "README.md"

repository = "https://github.com/colmugx/cetas"

license = "Apache-2.0"

keywords = [ "cetas", "tui", "native", "ratatui" ]

description = "Native Cetas TUI validation host backed by Ratatui"

preferred_target = "native"

supported_targets = "native"

options(
  "--moonbit-unstable-prebuild": "build.js",
)

import {
  "colmugx/posoco@0.20.4",
  "colmugx/cetas-core@0.2.0",
  "colmugx/posoco-ext-permission@0.2.0",
  "colmugx/posoco-ext-workspace@0.1.0",
  "colmugx/posoco-ext-fs-session@0.4.0",
  "moonbitlang/async@0.22.4",
  "moonbitlang/x@0.5.5",
  "posoco/devkit@0.4.1",
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
  // recipe-deps:end
}
