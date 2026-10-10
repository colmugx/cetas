# Configuration

[← Cetas](../README.md) · [中文首页](../README-zh.md)

## Providers and models

The interactive terminal is the easiest place to configure Cetas:

```text
/login
/model
```

`/login` presents provider-owned authentication methods, including API keys or OAuth where supported. `/model` selects the active model and effort. Provider configuration is stored in `~/.cetas/settings.json`; Cetas passes provider-specific settings to the selected extension rather than imposing one endpoint or credential schema.

The public recipe includes OpenAI, OpenAI-compatible endpoints, DeepSeek, Kimi, OpenRouter, Z.ai, Z.ai Coding Plan, and OpenCode Zen. Authentication methods and available models depend on the provider.

## Permissions

Use `/permission <mode>` in the interactive terminal, including during a turn:

| Mode | Behavior |
| --- | --- |
| `readonly` | Read tools are allowed; non-read tools are rejected. |
| `workspace_write` | Reads are allowed; writes, shell commands, and unknown tools go through UI confirmation. |
| `interactive` | Side-effecting tools require confirmation. |
| `yolo` | Tools are pre-approved without confirmation. This is the JS host's current default. |

Select the mode that fits the task before requesting changes. Permission policy belongs to the core; the host supplies the approval UI.

## Shared state

Cetas hosts use the following layout under the platform user home:

| Path | Contents |
| --- | --- |
| `~/.cetas/settings.json` | Provider settings and active model/effort |
| `~/.cetas/credentials/` | Provider credential storage |
| `~/.cetas/mcp.json` | User-level MCP server configuration |
| `~/.cetas/sessions/` | Project-bucketed session transcripts and companions |

The native, ACP, and runner entry points honor `CETAS_HOME` as an override for the **parent home**, not the `.cetas` directory. For example, `CETAS_HOME=/tmp/cetas-user` puts state in `/tmp/cetas-user/.cetas/`. The JS host currently uses the platform home through its host configuration.

Sharing settings and storage does not guarantee identical command flows or conversation-resume support in every host. See each host's guide for its current capabilities. [Memoh](../cetas-memoh/README.mbt.md) is a separate runtime with its own version and `~/.cetas-memoh/` state.

## MCP

The interactive terminal and ACP host compose the MCP extension. Server configuration can be supplied by `~/.cetas/mcp.json` or the project's `.mcp.json`; project entries take precedence for matching server names.

In ACP, local configured servers connect lazily on the first turn by default. Set `CETAS_MCP_MODE=eager` to connect them at startup. The editor can also provide MCP server definitions over ACP.

## Editor — ACP

1. Download and extract `cetas-acp` from the [Cetas release](https://github.com/colmugx/cetas/releases/tag/cetas-v0.7.0), or [build it](development.md#editor-and-runner).
2. Configure a provider first, for example using `/login` and `/model` in `cetas-bun`. ACP needs a configured model to serve prompts.
3. Register the executable as a custom agent in your editor.

For current Zed versions, add a top-level `agent_servers` entry to settings:

```json
{
  "agent_servers": {
    "Cetas": {
      "type": "custom",
      "command": "/absolute/path/to/cetas-acp",
      "args": [],
      "env": {}
    }
  }
}
```

Use `cetas-acp.exe` on Windows. Follow [Zed's official custom-agent instructions](https://zed.dev/docs/ai/external-agents#custom-agents) if your editor version uses a different schema. Launch Cetas with the project as its working directory; coding tools use the process working directory.

Model and effort selection arrive through ACP config options (`session/set_config_option`) and are persisted to the shared settings. For connection failures, inspect the editor's ACP logs and the agent's stderr.
