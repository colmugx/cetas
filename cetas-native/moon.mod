name = "colmugx/cetas-native"

version = "0.0.1"

readme = "README.md"

repository = "https://github.com/colmugx/cetas"

license = "Apache-2.0"

keywords = [ "cetas", "tui", "native", "ratatui" ]

description = "Native Cetas TUI validation host backed by Ratatui"

preferred_target = "native"

options(
  "--moonbit-unstable-prebuild": "build.js",
)
