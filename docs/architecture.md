# Architecture

[← Cetas](../README.md) · [Development](development.md)

Cetas is a product built on Posoco's protocol-first agent framework. Product semantics belong to the core; hosts bind extensions, platform services, transport, and presentation.

## Repository map

| Path | Responsibility |
| --- | --- |
| `cetas-core/` | Agent identity, prompts, platform/session assembly, lifecycle, routing and policy |
| `cetas-js/` | Bun host, application boundary, and pi-tui interactive terminal |
| `cetas-acp/` | Agent Client Protocol host for editors |
| `cetas-run/` | One-turn native/Wasm host for automation and MoonX |
| `cetas-native/` | Native terminal host; MoonBit application state, Rust terminal mechanics |
| `cetas-web/` | Browser host and web presentation |
| `cetas-ext-forme/` | Cetas identity/help extension |
| `composition/` | Human-edited capability roster and composition documentation |
| `*/**/recipe.mbt` | Checked-in public host composition roots |
| `extension/` | Posoco extension submodule |
| `cetas-memoh/` | Separately versioned Memoh runtime, with its own product semantics and state |

The Cetas hosts assemble `cetas-core` and Posoco's `Agent` rather than implementing their own agent loop. Memoh is a separate integration and does not depend on `cetas-core`.

## Capabilities

[`composition/recipes.csv`](../composition/recipes.csv) is the capability inventory. It describes shared infrastructure, recipe-constructed core capabilities, and host-specific integrations. Each host now declares its public concrete packages statically.

Shared entries include:

- Provider routing, OAuth, credentials, workspace/context, filesystem sessions, permissions, and rate limiting.
- Read/write/edit tools, glob/grep/ast-grep search, web fetch, Bash or PowerShell, skills, questions, handoff, and lazy tools.
- Provider extensions for OpenAI, OpenAI-compatible endpoints, DeepSeek, Kimi, OpenRouter, Z.ai, Z.ai Coding Plan, and OpenCode Zen.

Host integrations include MCP and planning in JS/ACP, ACP transport and editor adapters, and terminal-specific presentation or delegation extensions. Consult the roster for the exact host entries; do not maintain a second handwritten extension matrix.

The generator binds packages and constructors. It does not define product policy, and `cetas-core` remains recipe-invariant. A missing selected capability is a build error rather than a silent fallback.

## Shared identity and state

The core keeps the product identity consistent. A shared Cetas home makes provider settings, active model/effort, credentials, and session storage reusable. Hosts can still differ in UI capabilities and supported session flows; see [configuration](configuration.md).

## Visual identity

The Cetas mark is Modular Cut: a polygonal C built on an integer grid with 45° edges and two straight, equally wide cuts. The upper-left cut runs through the top edge. The README uses light/dark SVG variants in [`docs/assets/`](assets/); the documentation site uses an adaptive SVG and a favicon with wider cuts for small sizes. The JS welcome header uses a six-row half-block rendering of the same small-size cut. Regenerate these assets with `python3 scripts/update_brand.py`, or verify they match the shared geometry with `python3 scripts/update_brand.py --check`. Branding remains presentation; the welcome screen reads safe application snapshots and never parses provider secrets.
