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
  "colmugx/cetas-core@0.2.0",
  "colmugx/posoco-ext-permission@0.2.0",
  "colmugx/posoco-ext-workspace@0.1.0",
  "colmugx/posoco-ext-fs-session@0.3.0",
  "moonbitlang/async@0.22.3",
}
