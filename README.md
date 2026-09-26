# Cetas

**Cetas** is a coding agent built on [Posoco](https://github.com/colmugx/posoco),
a protocol-first LLM agent framework for MoonBit.

> Wherever you access Cetas, Cetas is there.
> However you access Cetas, it is the same Cetas.

### Repository layout

Every surface composes the same `cetas-core` assembly and the same Posoco
`Agent`; none contains agent-loop logic of its own, and none defines its own
identity. A new surface is a new way in — not a new Cetas.
Which extensions each outlet ships, and the build knobs: see

### Prerequisites

- The [MoonBit toolchain](https://docs.moonbitlang.com) (`moon`).
- [Bun](https://bun.sh) — only for `cetas-js`.
- This repo lives at `external/cetas` in the Posoco workspace and builds inside that workspace (`external/cetas/moon.work`). MoonBit dependencies resolve through the workspace / mooncakes.io.

### cetas-js — interactive terminal UI

```bash
cd cetas-js
bun run build
```

<!-- Build-time flavor selection: `CETAS_FLAVOR` (public|personal) picks the preference-tied extensions (nowledge-mem, rtk, obsidian — cetas-bun defaults to public, moon dev builds and cetas-acp to personal) and `CETAS_PLATFORM` (windows|unix) the shell tool; both bake into a gitignored `cetas-core/lib/build_config.mbt`, so after switching either, delete that file (or `moon clean`) before rebuilding. -->

Provider configuration lives in `.cetas/settings.json` under your home directory. The settings object is passed opaquely to the selected provider extension — Cetas itself never parses endpoints or credentials.

### cetas-acp — drive Cetas from an editor (Zed)

```bash
cd cetas-acp
moon build --target native --release
# binary lands at _build/native/release/build/colmugx/cetas-acp/main/main.exe
```

Launch it from the project root — tools run in the process working directory, matching how Zed spawns ACP agents.

Register the binary in Zed's settings (see [Zed's external-agents docs](https://zed.dev/docs/ai/external-agents) for the current schema):

```json
{
  "agent": {
    "acp_agents": {
      "cetas": {
        "command": "/absolute/path/to/cetas/_build/native/release/build/colmugx/cetas-acp/main/main.exe",
        "args": []
      }
    }
  }
}
```

Notes:

- A model provider must already be configured (`~/.cetas/settings.json` or a previous Cetas login) — an agent without a model cannot serve prompts, so startup fails loudly on stderr and exits.
- Model/effort selection arrives through ACP config options (`session/set_config_option`). Selection is process-global and is persisted back to `~/.cetas/settings.json`.
- `CETAS_HOME` overrides the Cetas home directory (settings, credentials, sessions); `HOME` is the default.
- MCP servers declared in `<cwd>/.mcp.json` (overriding `~/.cetas/mcp.json`) connect lazily at the first turn by default; set `CETAS_MCP_MODE=eager` to connect them all at startup.

### Native extension holdings

These are **build/composition-time Posoco extensions**, not runtime-installable
plugins. Rows are native extensions, columns are outlets — add a column when a
new outlet ships. ✓ = installed, — = not held.

Cetas reserves **plugin** for a runtime-installable package layer:
**extensions build Cetas; plugins extend Cetas**. See
[the plugin architecture note](docs/plugin-architecture.md) for the boundary.

| Native extension | cetas-bun | cetas-acp | cetas-headless |
|---|---|---|---|
| **Tools** | | | |
| `posoco-ext-read` / `-write` / `-edit` | ✓ | ✓ | ✓ |
| `posoco-ext-glob` / `-grep` | ✓ | ✓ | ✓ |
| `posoco-ext-astgrep` (structural code search via ast-grep) | ✓ | ✓ | ✓ |
| `posoco-ext-bash` / `-ps1` | ✓ | ✓ | ✓ |
| `posoco-ext-webfetch` | ✓ | ✓ | ✓ |
| `posoco-ext-askquestion` | ✓ | ✓ | ✓ |
| `posoco-ext-skills` | ✓ | ✓ | ✓ |
| `posoco-ext-handoff` | ✓ | ✓ | ✓ |
| `cetas-ext-forme` | ✓ | ✓ | ✓ |
| `posoco-ext-lazytools` | ✓ | ✓ | ✓ |
| **Model ports** | | | |
| `posoco-ext-deepseek` / `-kimi` / `-openai` / `-openai-compatible` / `-opencode-zen` / `-zai` / `-zai-coding-plan` / `-openrouter` | ✓ | ✓ | ✓ |
| `posoco-kit-chat-completions` / `-responses` / `-compact-evict` / `-compact-summary` | ✓ (transitive) | ✓ (transitive) | ✓ (transitive) |
| **Infrastructure** | | | |
| `posoco-ext-llm` | ✓ | ✓ | ✓ |
| `posoco-ext-oauth` | ✓ | ✓ | ✓ |
| `posoco-ext-credentials` | ✓ | ✓ | ✓ |
| `posoco-ext-context` | ✓ | ✓ | ✓ |
| `posoco-ext-workspace` | ✓ | ✓ | ✓ |
| `posoco-ext-fs-session` | ✓ | ✓ | ✓ |
| `posoco-ext-permission` | ✓ | ✓ | ✓ |
| `posoco-ext-ratelimit` | ✓ | ✓ | ✓ |
| `posoco-devkit` | ✓ | ✓ | ✓ |
| **Preference-tied** (baked per outlet) | | | |
| `posoco-ext-nowledge-mem` | — | ✓ | ✓ |
| `posoco-ext-rtk` | — | ✓ | ✓ |
| `posoco-ext-obsidian` | — | — | — |
| **Outlet-specific** | | | |
| `posoco-ext-herdr` | ✓ (presence + `herdr_delegate`) | — | ✓ (presence only) |
| `posoco-ext-mcp` | ✓ | ✓ | — |
| `posoco-ext-plan` | ✓ | ✓ | — |
| `posoco-ext-goal` | ✓ | ✓ | — |
| `posoco-ext-statusbar` / `-stats` | ✓ | — | — |
| `posoco-ext-pi-adaptor` | ✓ | — | — |
| `posoco-ext-zcode` | — | ✓ ¹ | — |
| `posoco-ext-acp` | — | ✓ | — |
| `posoco-kit-lody` / `-paseo` | — | ✓ | — |
| `posoco-kit-delegation` | — | ✓ (transitive) | — |

> `posoco-ext-herdr`: cetas-headless reports presence only and never gets
> `herdr_delegate` — headless is a depth-1 leaf (2026-09-10 hard rule), so a
> delegated child cannot delegate further; pane delegation composes in
> cetas-bun only.

### Shared state — what "the same Cetas" means today

All surfaces read and write the same Cetas home (default `~/.cetas/`):
`settings.json` (provider config + active model/effort), credential files,
`mcp.json`, and JSONL session transcripts under `sessions/`. That shared
home is what makes the definition literal today: log in once, and every
surface is signed in; pick a model once, and every surface uses it.
Continuing one conversation across surfaces (cross-host session resume) is
the next piece of the definition.
