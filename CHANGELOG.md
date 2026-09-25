# Changelog

Entries in this file are written by `scripts/release.py` at release time, as `## X.Y.Z (YYYY-MM-DD)` sections ordered newest first.

## 0.5.0 (2026-09-25)

## Bun Ver.（cetas-js/cetas-bun）

### Feats
- Isolated subagents are now wired into the JS/Bun host.
- Plan mode gets first-class UI.
- Codex OAuth credentials are renewed automatically at load time.
- Shell execution is fully cancellable with graceful termination followed by a hard-kill fallback, and shell runtime handling across the host is more robust.
- Zcode delegation now supports background execution with proper task management, so long delegations keep the conversation responsive.
- The stats panel now reports token accounting and cache-aware usage, distinguishing unknown from genuinely zero cache telemetry.
- Skills get semantic search.
- The model now adjusts reasoning effort per call via a DecisionPort, spending tokens where they matter.
- AskQuestion gains lifecycle management with an optional UI port for cleaner interactive prompts.
- Tool outputs across the built-in toolkit are now bounded and compacted, dramatically cutting context token waste per turn.
- MCP external tool schemas and results, memory tool outputs, and deferred-tool payloads are capped and compacted, keeping long sessions lean.
- Subagents gained a global concurrency cap and a fresh per-run spawn budget, so long-lived sessions never silently exhaust their delegation allowance.
- Prompt-cache rejection state is now shared and preserved across rebuilds, protecting your cache hit rates.
- The herdr channel adds regex matching and background delegation, with restored resident delegation strategy and deferred-tool guidance.
- The lazy-tools meta layer keeps stable manifest surfaces and falls back to semantic DecisionPort matching when tool discovery is ambiguous.
- OpenCode Zen model retrieval is now async and more reliable for live catalog refreshes.

### Fixes
- Invalid CLI flag values now fail fast with clear error messages instead of confusing failures, and session management is steadier.
- Oversized prompt-cache keys are now hashed instead of rejected outright.

## ACP Ver.（cetas-acp）

### Feats
- Isolated subagents are now available over ACP.
- A new `auto` permission mode joins readonly / workspace_write / interactive / yolo, letting a DecisionPort preapprove safe actions automatically.
- Agents now stream thought chunks to the client immediately via `push_agent_thought_chunk`, so you see reasoning as it happens.
- Session renaming lands as a slash command: `/name <title>` retitles the persisted session and pushes the new name straight to your client.
- Codex OAuth credentials renew automatically at load time, with a full OAuth transport for the OpenAI provider.
- Shell execution is fully cancellable with graceful termination and a hard-kill fallback.
- Zcode delegation supports background execution with proper task management.
- Skills get semantic search, and the lazy-tools layer falls back to semantic matching for tool discovery.
- The model adjusts reasoning effort per call via a DecisionPort; `auto` permission mode is backed by tightened DecisionPort preapproval.
- AskQuestion gains lifecycle management with an optional UI port.
- Built-in tool outputs are bounded and compacted, along with MCP schemas and memory tool results, to cut context waste.
- Subagents gained a global concurrency cap and a fresh per-run spawn budget per turn.
- Prompt-cache rejection state is shared and preserved for providers.
- User request lifecycle events are now ingested into the ACP bridge for more accurate client state.

### Fixes
- Cancelled turns no longer leave the model transport in a broken state; cancellation handling is cleaner end to end.

## Headless Ver.（cetas-headless）

### Feats
- cetas-headless is now part of the release pipeline and published.
- A new `auto` permission mode is available via `--permission auto` (and `--yolo` remains for unattended runs), backed by DecisionPort preapproval.
- Shell execution is fully cancellable with graceful termination and a hard-kill fallback.
- Skills get semantic search, and the lazy-tools layer falls back to semantic matching for tool discovery.
- The model adjusts reasoning effort per call via a DecisionPort.
- AskQuestion gains lifecycle management for cleaner interactive prompts.
- Prompt-cache rejection state is shared and preserved for Kimi, OpenRouter, and OpenAI-compatible providers.

### Fixes
- Invalid CLI flag values now produce clear error messages instead of silent misbehavior, and run-loop session handling is more reliable.

## 0.4.0 (2026-09-11)

## Bun Ver.（cetas-js/cetas-bun）

### Feats
- Model picker now shows provider quota windows and per-model pricing badges so you can pick the right model before spending tokens.
- Faster app launch when opening the model picker.
- New `/model quick-pick` command groups models by usage limits, balance, and other quick figures for one-keystroke switching.
- DeepSeek models gained explicit reasoning-effort levels and built-in pricing information.
- Herd progress reporting now runs on a dedicated delegate with a full JS backend channel for the bun terminal UI.
- The rtk command wrapper gained dedicated rewriter backends per runtime for more reliable command execution.

## ACP Ver.（cetas-acp）

### Feats
- DeepSeek models gained explicit reasoning-effort levels and built-in pricing information.

## Headless Ver.（cetas-headless）

### Feats
- Herd progress reporting now runs on a dedicated delegate with a native backend channel for one-shot runs.

## 0.3.2 (2026-09-09)

## Bun Ver.（cetas-js/cetas-bun）

### Feats

- Update package configurations to support native and JS targets

### Fixes

- Update posoco dependency to 0.15.0 and clean up unused imports in extensions
- Remove strconv dependency and fix string conversion in the Kimi extension usage reporting
- Update DeepSeek reasoning effort values to include `low` and improve model catalog handling

## ACP Ver.（cetas-acp）

### Feats

- Update package configurations to support native and JS targets

### Fixes

- Update posoco dependency to 0.15.0 and clean up unused imports in extensions
- Wrap libc system calls in a prefixed shim to avoid prototype collisions on Linux
- Remove strconv dependency and fix string conversion in the Kimi extension usage reporting
- Update DeepSeek reasoning effort values to include `low` and improve model catalog handling

## Headless Ver.（cetas-headless）

### Feats

- Rework output handling with StreamPrinter for clean stdout output
- Update package configurations to support native and JS targets

### Fixes

- Update posoco dependency to 0.15.0 and clean up unused imports in extensions
- Wrap libc system calls in a prefixed shim to avoid prototype collisions on Linux
- Remove strconv dependency and fix string conversion in the Kimi extension usage reporting
- Update DeepSeek reasoning effort values to include `low` and improve model catalog handling

## 0.3.1 (2026-09-09)

## Bun Ver.（cetas-js/cetas-bun）

### Feats
- Session titles are now generated and managed, with improved in-app session management
- New `posoco-ext-stats` extension providing speed metrics and cache accounting
- Zcode task delegation and tool integration
- Companion path resolution, session renaming, and project directory handling in session management
- Enhanced context state management with a new ctx segment
- Cross-platform user home resolution for more reliable configuration paths

### Fixes
- Stats reporting improvements
- MCP user `mcp.json` path handling on the user level
- More informative webfetch error messages for blocked hosts
- Statusbar now correctly reports valued segments
- Improved prompt cache key handling for better cache reuse

## ACP Ver.（cetas-acp）

### Feats
- Per-project session storage and slash command handling
- Session info updates surfaced to clients
- Zcode task delegation and tool integration
- Companion path resolution, session renaming, and project directory handling in session management
- Enhanced context state management with a new ctx segment
- Cross-platform user home resolution for more reliable configuration paths

### Fixes
- MCP user `mcp.json` path handling on the user level
- More informative webfetch error messages for blocked hosts
- Improved prompt cache key handling for better cache reuse
- More robust SSE stream processing and error handling for responses-based models

## Headless Ver.（cetas-headless）

### Feats
- Enhanced JsonlObserver and TraceObserver for improved event streaming
- Enhanced context state management with a new ctx segment
- Cross-platform user home resolution for more reliable configuration paths

### Fixes
- MCP user `mcp.json` path handling on the user level
- More informative webfetch error messages for blocked hosts
- Improved prompt cache key handling for better cache reuse
