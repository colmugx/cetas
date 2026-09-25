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
  "colmugx/posoco@0.18.5",
  "moonbitlang/async@0.22.3",
}
