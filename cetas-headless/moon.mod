// cetas-headless — terminal-text-world cetas host (one-shot turn over stdio).
//
// Target: native. One invocation = one user turn; the task comes from argv
// after `--` or from one stdin line, and results go to stdout as a session
// line, a human-readable summary line, and a fixed completion marker line.
// Approval prompts and interactive UI requests bypass stdin via /dev/tty
// (ssh-style), so the task protocol stays pure. Agent logic reuses
// cetas-core; this package is only the shell.

name = "colmugx/cetas-headless"

version = "0.1.0"

readme = "README.mbt.md"

repository = ""

license = "Apache-2.0"

keywords = [ "cetas", "headless", "stdio", "one-shot", "agent" ]

description = "Cetas headless host — runs exactly one cetas user turn per invocation (argv task or one stdin line) with a /dev/tty interactive bypass"

import {
  "colmugx/posoco@0.14.5",
  "colmugx/cetas-core@0.2.0",
  "colmugx/posoco-devkit@0.3.0",
  "colmugx/posoco-ext-goal@0.2.0",
  "colmugx/posoco-ext-llm@0.2.0",
  "colmugx/posoco-ext-mcp@0.4.0",
  "colmugx/posoco-ext-permission@0.2.0",
  "colmugx/posoco-ext-plan@0.3.0",
  "colmugx/posoco-ext-workspace@0.1.0",
  "colmugx/posoco-ext-zcode@0.1.0",
  "moonbitlang/async@0.21.2",
}
