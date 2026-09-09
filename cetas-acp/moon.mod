// cetas-acp — ACP (Agent Client Protocol) host for cetas.
//
// Target: native. Serves one cetas agent over stdio as an ACP v1 agent so
// editors such as Zed can drive it. Agent logic reuses cetas-core; the
// protocol adaptation is posoco-ext-acp's AcpBridge; the wire runtime is
// colmugx/acp.

name = "colmugx/cetas-acp"

version = "0.3.1"

readme = "README.mbt.md"

repository = ""

license = "Apache-2.0"

keywords = [ "cetas", "acp", "agent-client-protocol", "zed", "stdio" ]

description = "Cetas ACP host — serves a cetas agent over stdio via Agent Client Protocol v1"

import {
  "colmugx/posoco@0.15.0",
  "colmugx/acp@0.2.0",
  "colmugx/posoco-ext-acp@0.3.0",
  "colmugx/posoco-ext-permission@0.2.0",
  "colmugx/cetas-core@0.2.0",
  "colmugx/mcp@0.17.5",
  "colmugx/posoco-devkit@0.3.0",
  "colmugx/posoco-ext-context@0.2.0",
  "colmugx/posoco-ext-credentials@0.1.0",
  "colmugx/posoco-ext-fs-session@0.3.0",
  "colmugx/posoco-ext-goal@0.2.0",
  "colmugx/posoco-ext-llm@0.2.0",
  "colmugx/posoco-ext-mcp@0.4.0",
  "colmugx/posoco-ext-oauth@0.1.0",
  "colmugx/posoco-ext-plan@0.3.0",
  "colmugx/posoco-ext-webfetch@0.1.0",
  "colmugx/posoco-ext-workspace@0.1.0",
  "colmugx/posoco-ext-zcode@0.1.0",
  "colmugx/posoco-ext-ratelimit@0.3.0",
  "colmugx/posoco-kit-lody@0.1.0",
  "colmugx/posoco-kit-paseo@0.1.0",
  "moonbitlang/async@0.21.2",
}
