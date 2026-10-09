// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "colmugx/cetas-core"

version = "0.2.0"

readme = "README.mbt.md"

repository = "https://github.com/colmugx/cetas"

license = "Apache-2.0"

keywords = [ "cetas", "posoco", "host", "core" ]

description = "Cetas core — host-agnostic application/domain logic shared by every Cetas surface"

import {
  "colmugx/posoco@0.22.0",
  "posoco/devkit@0.4.1",
  "posoco/ext-llm@0.2.0",
  "posoco/ext-oauth@0.1.0",
  "colmugx/posoco-ext-deepseek@0.2.0",
  "colmugx/posoco-ext-kimi@0.2.0",
  "colmugx/posoco-ext-openai@0.1.0",
  "colmugx/posoco-ext-openai-compatible@0.2.0",
  "colmugx/posoco-ext-opencode-zen@0.2.0",
  "colmugx/posoco-ext-zai@0.1.0",
  "colmugx/posoco-ext-zai-coding-plan@0.1.0",
  "colmugx/posoco-ext-openrouter@0.1.0",
  "colmugx/posoco-ext-workspace@0.1.0",
  "colmugx/posoco-ext-context@0.2.0",
  "colmugx/posoco-ext-credentials@0.1.0",
  "colmugx/posoco-ext-fs-session@0.4.0",
  "colmugx/posoco-ext-permission@0.2.0",
  "colmugx/posoco-ext-ratelimit@0.4.0",
  "moonbitlang/async@0.22.4",
}
