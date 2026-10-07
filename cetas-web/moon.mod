name = "colmugx/cetas-web"

version = "0.1.0"

repository = "https://github.com/colmugx/cetas"

license = "Apache-2.0"

keywords = [ "cetas", "web", "solid", "moonback", "agent" ]

description = "Cetas web host — Solid 2 frontend served by a Moonback native host"

preferred_target = "native"

supported_targets = "native"

import {
  "colmugx/posoco@0.21.1",
  "colmugx/cetas-core@0.2.0",
  "posoco/devkit@0.4.1",
  "colmugx/posoco-ext-permission@0.2.0",
  "colmugx/posoco-ext-workspace@0.1.0",
  "moonbitlang/async@0.22.4",
  "moonbitlang/moonback@0.8.5",
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
  "posoco/ext-llm@0.2.0",
  "colmugx/posoco-ext-fs-session@0.4.0",
  "colmugx/posoco-ext-statusbar@0.3.0",
  "colmugx/posoco-ext-stats@0.1.0",
}
