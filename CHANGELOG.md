# Changelog

Entries in this file are written by `scripts/release.py` at release time, as `## X.Y.Z (YYYY-MM-DD)` sections ordered newest first.

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

## Unreleased

## Bun Ver.（cetas-js/cetas-bun）

### Feats

- New `herdr_delegate` tool from posoco-ext-herdr 0.1.0: pane delegation to a depth-1 cetas-headless child over a herdr CLI channel (concurrency cap 4, readonly by default), wired env-gated at composition
- `herdr_delegate` now contributes a herdr-context system-prompt section (pane identity + delegation strategy) via the SystemPromptContributor port, and its tool description carries when-to-use guidance
- `herdr_delegate` gains a `direction` split argument (`right` default, `down`) and success-only auto-close of the child pane (`close_pane`, default true; close failure degrades to a note footer, and failures/timeouts never close the pane)
- `herdr_delegate` flows `child_session` back to the parent on failure and (best-effort, read-failure-tolerant) timeout paths too — not just success — and its system-prompt section and tool description now require related tasks to reuse the same child session via the `session` argument

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
