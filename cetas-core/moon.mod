// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "colmugx/cetas-core"

version = "0.2.0"

readme = "README.mbt.md"

repository = ""

license = "Apache-2.0"

keywords = [ "cetas", "posoco", "host", "core" ]

description = "Cetas core — target-agnostic host logic (assembly, slash, observer, session) for cetas-native and cetas-js"

import {
  "colmugx/posoco@0.14.0",
  "colmugx/posoco-devkit@0.1.0",
  "colmugx/cetas-ext-forme@0.1.0",
  "colmugx/posoco-ext-read@0.2.0",
  "colmugx/posoco-ext-write@0.2.0",
  "colmugx/posoco-ext-edit@0.2.0",
  "colmugx/posoco-ext-bash@0.2.0",
  "colmugx/posoco-ext-ps1@0.1.0",
  "colmugx/posoco-ext-glob@0.2.0",
  "colmugx/posoco-ext-grep@0.2.0",
  "colmugx/posoco-ext-webfetch@0.1.0",
  "colmugx/posoco-ext-llm@0.1.0",
  "colmugx/posoco-ext-skills@0.2.0",
  "colmugx/posoco-ext-nowledge-mem@0.1.0",
  "colmugx/posoco-ext-herdr@0.1.0",
  "colmugx/posoco-ext-askquestion@0.1.0",
  "colmugx/posoco-ext-rtk@0.3.0",
  "colmugx/posoco-ext-oauth@0.1.0",
  "colmugx/posoco-ext-deepseek@0.2.0",
  "colmugx/posoco-ext-kimi@0.2.0",
  "colmugx/posoco-ext-openai@0.1.0",
  "colmugx/posoco-ext-openai-compatible@0.1.1",
  "colmugx/posoco-ext-opencode-zen@0.1.1",
  "colmugx/posoco-ext-zai@0.1.0",
  "colmugx/posoco-ext-zai-coding-plan@0.1.0",
  "colmugx/posoco-ext-openrouter@0.1.0",
  "colmugx/posoco-ext-workspace@0.1.0",
  "colmugx/posoco-ext-handoff@0.1.0",
  "colmugx/posoco-ext-obsidian@0.1.0",
  "colmugx/posoco-ext-lazytools@0.1.0",
  "moonbitlang/async@0.21.0",
}
