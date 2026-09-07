# Cetas

**Cetas** is a coding agent built on [Posoco](https://github.com/colmugx/posoco),
a protocol-first LLM agent framework for MoonBit.

> Wherever you access Cetas, Cetas is there.
> However you access Cetas, it is the same Cetas.

### Repository layout

Every surface composes the same `cetas-core` assembly and the same Posoco
`Agent`; none contains agent-loop logic of its own, and none defines its own
identity. A new surface is a new way in — not a new Cetas.

### Prerequisites

- The [MoonBit toolchain](https://docs.moonbitlang.com) (`moon`).
- [Bun](https://bun.sh) — only for `cetas-js`.
- This repo lives at `external/cetas` in the Posoco workspace and builds inside that workspace (`external/cetas/moon.work`). MoonBit dependencies resolve through the workspace / mooncakes.io.

### cetas-js — interactive terminal UI

```bash
cd cetas-js
bun run build
```

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

### Releasing

Releases are cut by running `python3 scripts/release.py` from the repo root: it suggests a version from git history, opens your editor for the release notes, syncs `VERSION` and the component version files, updates `CHANGELOG.md`, and creates the annotated `cetas-vX.Y.Z` tag. Pushing that tag triggers `.github/workflows/release.yml`, which builds cetas-bun (bun-embedded binaries) and cetas-acp (native binaries) for darwin-arm64 / windows-x64 / linux-x64 and attaches them, with SHA256SUMS, to the GitHub Release. `python3 scripts/release.py check` is the version-consistency gate.

### Shared state — what "the same Cetas" means today

All surfaces read and write the same Cetas home (default `~/.cetas/`):
`settings.json` (provider config + active model/effort), credential files,
`mcp.json`, and JSONL session transcripts under `sessions/`. That shared
home is what makes the definition literal today: log in once, and every
surface is signed in; pick a model once, and every surface uses it.
Continuing one conversation across surfaces (cross-host session resume) is
the next piece of the definition.
