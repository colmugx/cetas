<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/cetas-symbol-dark.svg">
    <img src="docs/assets/cetas-symbol.svg" alt="Cetas" width="112" height="112">
  </picture>
  <h1>Cetas</h1>
  <p><strong>One agent. Every surface.</strong></p>
  <p>A coding agent for your terminal, editor, and scripts.<br>Built with MoonBit. Powered by <a href="https://github.com/colmugx/posoco">Posoco</a>.</p>
  <p>
    <a href="https://github.com/colmugx/cetas/actions/workflows/ci.yml"><img src="https://github.com/colmugx/cetas/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-256C63" alt="Apache 2.0"></a>
    <a href="https://www.moonbitlang.com"><img src="https://img.shields.io/badge/built%20with-MoonBit-256C63" alt="Built with MoonBit"></a>
  </p>
  <p><a href="https://github.com/colmugx/cetas/releases/tag/cetas-v0.7.0">Download</a> · <a href="#quick-start">Quick start</a> · <a href="#documentation">Documentation</a> · <a href="README-zh.md">简体中文</a></p>
</div>

![Cetas interactive terminal welcome screen](docs/assets/cetas-terminal.png)

<p align="center"><sub>The <code>cetas-js</code> welcome screen on main. Release binaries may have an earlier UI.</sub></p>

Cetas reads your code, makes edits, runs commands, and streams its work as it goes. Start in the terminal, connect it to an editor through ACP, or give it a single task from a script.

The product lives in **`cetas-core`**. Its hosts compose the same agent identity, prompts, and lifecycle on [Posoco](https://github.com/colmugx/posoco), with adapters for each surface. Provider settings, credentials, and session storage use a shared Cetas home.

## Why Cetas

- **Work with the repository.** Read, write, and edit files; search by path, text, or syntax; run Bash or PowerShell commands.
- **Choose your model.** Provider extensions include OpenAI, OpenAI-compatible endpoints, DeepSeek, Kimi, OpenRouter, Z.ai, and OpenCode Zen. Use `/login` and `/model` in the interactive terminal.
- **Extend the workflow.** Load skills and connect MCP tools in the interactive terminal and ACP host. Capability composition is explicit and recipe-driven.
- **Keep the conversation useful.** Stream responses and tool activity, queue follow-ups, browse sessions, and rewind in `cetas-js`.
- **Use the right entrance.** An interactive TUI for day-to-day work, ACP for editors, and a one-turn runner for automation.

## Quick start

### 1. Download the interactive terminal

The published **Cetas v0.7.0** terminal executable is named `cetas-bun`. It includes the Bun runtime; you do not need to install Bun or MoonBit to use the binary.

| Platform | Download |
| --- | --- |
| macOS · Apple Silicon | [cetas-bun-darwin-arm64.tar.gz](https://github.com/colmugx/cetas/releases/download/cetas-v0.7.0/cetas-bun-darwin-arm64.tar.gz) |
| Linux · x64 | [cetas-bun-linux-x64.tar.gz](https://github.com/colmugx/cetas/releases/download/cetas-v0.7.0/cetas-bun-linux-x64.tar.gz) |
| Windows · x64 | [cetas-bun-windows-x64.zip](https://github.com/colmugx/cetas/releases/download/cetas-v0.7.0/cetas-bun-windows-x64.zip) |

Extract the archive, then launch the executable **from the project you want to work on**. For example:

```bash
cd /path/to/your/project
/path/to/extracted/cetas-bun
```

On Windows, use the extracted `cetas-bun.exe`. The [release page](https://github.com/colmugx/cetas/releases/tag/cetas-v0.7.0) also includes ACP and runner binaries, plus checksums. Memoh has its own release series; use the Cetas-tagged release for these hosts.

### 2. Connect a model

In the terminal, run:

```text
/login
/model
```

Choose a provider, complete its authentication flow, then select a model. Settings and credentials are stored under `~/.cetas/` and reused by the other Cetas hosts.

### 3. Give Cetas a task

```text
Explain how authentication works in this repository.
```

```text
Fix the failing tests and show me what changed.
```

Use `@path` to include a file reference. `/help` lists commands and keyboard shortcuts. To select a permission mode, use `/permission readonly`, `/permission workspace_write`, `/permission interactive`, or `/permission yolo`; see the [configuration guide](docs/configuration.md) for their behavior.

## Every surface

| Surface | Best for | Entry point |
| --- | --- | --- |
| **Interactive terminal** · `cetas-js` | Streaming conversations, model/login pickers, sessions and rewind | `cetas-bun` · [Build from source](docs/development.md#interactive-terminal) |
| **Editor** · `cetas-acp` | Editors with Agent Client Protocol support | `cetas-acp` · [Setup](docs/configuration.md#editor--acp) |
| **Automation** · `cetas-run` | One task per invocation, scripts and JSONL output | `cetas-run` · [Guide](cetas-run/README.mbt.md) |
| **Native terminal** · `cetas-native` | MoonBit + Rust terminal host under development | [Status and build instructions](cetas-native/README.md) |
| **Web** · `cetas-web` | Browser host under development | [Local development](cetas-web/README.md) |

Host capabilities differ; the [composition roster](composition/recipes.csv) is the source of truth. Sharing the Cetas home does not imply every host has the same UI or cross-host conversation-resume support.

<details>
<summary><strong>Run one task from a script</strong></summary>

After configuring a provider, use the runner binary from the Cetas release:

```bash
cetas-run -- "explain this repository"
cetas-run --jsonl --stream -- "summarize the changes"
cetas-run --session <id> -- "continue"
```

The normal answer goes to stdout; diagnostics and lifecycle information go to stderr. With [MoonX](https://github.com/moonbitlang/moon), you can also run the Mooncakes module:

```bash
moonx colmugx/cetas-run -- -- "explain this repository"
```

See the [runner guide](cetas-run/README.mbt.md) for the native and sandboxed Wasm targets.

</details>

## Built on Posoco

Cetas began as a way to put [Posoco](https://github.com/colmugx/posoco) into people's hands: a useful coding agent that demonstrates what a protocol-first framework can do in everyday work.

Posoco provides the agent foundation and extension ports. Cetas owns the product behavior. Each host supplies its transport and UI. That separation lets the product grow across surfaces while keeping one core identity.

## Documentation

| Guide | What you will find |
| --- | --- |
| [Configuration](docs/configuration.md) | Providers, permissions, shared state, MCP and ACP setup |
| [Development](docs/development.md) | Workspace checkout, dependencies, builds and checks |
| [Architecture](docs/architecture.md) | Product ownership, repository layout and extension composition |
| [Composition](composition/README.md) | Recipe vocabulary and generator workflow |
| [Changelog](CHANGELOG.md) | Cetas core release history |
| [Memoh integration](cetas-memoh/README.mbt.md) | The separately versioned Memoh runtime and its own state directory |

## Contributing

Bug reports, focused improvements, and new host integrations are welcome. [Open an issue](https://github.com/colmugx/cetas/issues) with the host, version, platform, and steps to reproduce, or send a pull request with the relevant checks from the [development guide](docs/development.md).

For capability changes, update the composition roster; for product behavior, start in `cetas-core`.

## License

[Apache 2.0](LICENSE).
