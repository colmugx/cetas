// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "colmugx/cetas-core"

version = "0.1.0"

readme = "README.mbt.md"

repository = ""

license = "Apache-2.0"

keywords = [ "cetas", "posoco", "host", "core" ]

description = "Cetas core — target-agnostic host logic (assembly, slash, observer, session) for cetas-native and cetas-js"

import {
  "colmugx/posoco@0.5.2",
  "colmugx/posoco-ext-deepseek@0.1.0",
  "colmugx/posoco-ext-read@0.1.0",
  "colmugx/posoco-ext-write@0.1.0",
  "colmugx/posoco-ext-edit@0.1.0",
  "colmugx/posoco-ext-bash@0.1.0",
  "colmugx/posoco-ext-glob@0.1.0",
  "colmugx/posoco-ext-grep@0.1.0",
  "colmugx/posoco-ext-log@0.1.0",
  "moonbitlang/async@0.20.5",
}
