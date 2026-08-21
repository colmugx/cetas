# Cetas

**Cetas** is a coding agent built on [Posoco](https://github.com/colmugx/posoco),
a protocol-first LLM agent framework for MoonBit.

### Repository layout

| Directory | What it is |
|---|---|
| [`cetas-core/`](./cetas-core/) | Library. Target-agnostic host logic shared by every host: the `Cetas` extension (identity, system-prompt assembly, `/profile` command), provider assembly / credentials / login, model catalog cache, and the prompt runner. It performs no target-specific IO — all IO is injected by the host. |
| [`cetas-js/`](./cetas-js/) | **Terminal UI host.** Runs on the **Bun** runtime (js target) with Node-compatible `node:fs` / `node:crypto` FFI, and renders with **pi-tui**. |
| [`cetas-acp/`](./cetas-acp/) | **Editor host.** Native executable that serves one Cetas agent over stdio as an **ACP v1** agent, so ACP clients such as **Zed** can drive it. |

Both hosts reuse `cetas-core`; neither contains agent-loop logic of its own — that belongs to the Posoco `Agent` they compose.

### Prerequisites

- The [MoonBit toolchain](https://docs.moonbitlang.com) (`moon`).
- [Bun](https://bun.sh) — only for `cetas-js`.
- This repo is developed as the `external/examples` submodule of Posoco and builds inside that workspace (`external/moon.work`). MoonBit dependencies resolve through the workspace / mooncakes.io.

### cetas-js — interactive terminal UI

```bash
cd external/examples/cetas-js
moon build --target js --release     # builds the MoonBit side into _build/js/release/build/colmugx/cetas-js/lib/lib.js
bun install
bun run start              # = bun host.ts — full TUI
```

- Type a prompt and press Enter. Tool calls stream in as they happen; assistant replies render as Markdown.
- `/model` opens the model picker (`All` + provider tabs; ←/→ selects the reasoning effort of the highlighted model).
- `/login` configures a provider via API key or OAuth (Codex/Kimi uses the device-code flow; the overlay shows URL and code).
- `/help` lists all slash commands (`/clear`, `/new`, `/skills`, `/exit`, …).

Provider configuration lives in `.cetas/settings.json` under your home directory. The settings object is passed opaquely to the selected provider extension — Cetas itself never parses endpoints or credentials.

### cetas-acp — drive Cetas from an editor (Zed)

```bash
cd external/examples/cetas-acp
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
        "command": "/absolute/path/to/external/_build/native/debug/build/colmugx/cetas-acp/main/main.exe",
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

### Shared state

Both hosts read and write the same Cetas home (default `~/.cetas/`): `settings.json` (provider config + active model/effort), credential files, `mcp.json`, and JSONL session transcripts under `sessions/`.