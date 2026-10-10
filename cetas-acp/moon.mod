// cetas-acp — ACP (Agent Client Protocol) host for cetas.
//
// Target: native. Serves one cetas agent over stdio as an ACP v1 agent so
// editors such as Zed can drive it. Agent logic reuses cetas-core; the
// protocol adaptation is posoco-ext-acp's AcpBridge; the wire runtime is
// colmugx/acp.

name = "colmugx/cetas-acp"

version = "0.7.0"

readme = "README.mbt.md"

repository = "https://github.com/colmugx/cetas"

license = "Apache-2.0"

keywords = [ "cetas", "acp", "agent-client-protocol", "zed", "stdio" ]

description = "Cetas ACP host — serves a cetas agent over stdio via Agent Client Protocol v1"

preferred_target = "native"

supported_targets = "native"

import {
  "colmugx/posoco@0.22.0",
  "colmugx/acp@0.2.1",
  "colmugx/cetas-core@0.2.0",
  "colmugx/mcp@0.17.5",
  "posoco/devkit@0.4.1",
  "colmugx/posoco-ext-context@0.2.0",
  "colmugx/posoco-ext-credentials@0.1.0",
  "colmugx/posoco-ext-fs-session@0.4.0",
  "posoco/ext-llm@0.2.0",
  "posoco/ext-oauth@0.1.0",
  "colmugx/posoco-ext-permission@0.2.0",
  "colmugx/posoco-ext-ratelimit@0.4.0",
  "colmugx/posoco-ext-workspace@0.1.0",
  "moonbitlang/async@0.22.4",
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
  "colmugx/posoco-ext-acp@0.3.0",
  "colmugx/posoco-ext-mcp@0.5.1",
  "colmugx/posoco-ext-plan@0.5.0",
  "colmugx/posoco-kit-lody@0.1.0",
  "colmugx/posoco-kit-paseo@0.1.0",
  // recipe-deps:end
}
