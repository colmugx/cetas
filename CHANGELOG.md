# Changelog

Entries in this file are written by `scripts/release.py` at release time, as `## X.Y.Z (YYYY-MM-DD)` sections ordered newest first.

## 0.7.0 (2026-09-30)

## General

### Feats
- Your saved model choice is never silently swapped anymore.

## Bun Ver.（cetas-bun）

### Feats
- Configure your subagent fleet from `~/.cetas/settings.json`: a new optional `subagent` section lets you restrict which model slots and reasoning efforts subagents may use, pin a default subagent model, and cap swarm size, per-group/global concurrency, timeouts, and spawn budget.
- Subagent kinds can now pin a reasoning effort.
- OpenAI/Codex model lists now survive offline.

### Fixes
- Switching models while a rate-limit retry is scheduled now cancels the stale follow-up before the switch, so an outdated retry can no longer fire after you've moved to another model or duplicate your requests.

## ACP Ver.（cetas-acp）

### Feats
- Startup now honors your saved model.
- OpenAI/Codex catalogs rebuild from cached discovery records, so the full model list — not just a single static model — is available offline after a prior refresh.

### Fixes
- Every ACP session now holds its own agent task scope for its whole lifetime, so background and delegated work can be submitted from the first prompt and is shut down cleanly when the session retires.

## Run Ver.（cetas-run）

### Feats
- Log in from the terminal: `cetas-run --login [provider]` runs the full authentication flow standalone, saves credentials to the shared Cetas home, refreshes the model catalog, and lets you pick your initial model (auto-selected when only one is available). Wasm builds get clear guidance to log in via Cetas `/login` with the same home.
- cetas-run is now published on Mooncakes: run one-shot turns anywhere with `moonx colmugx/cetas-run -- --yolo -- "your task"` — built for scripts, CI pipelines, agent swarms, and sandboxed MoonX execution.
- Friendlier first run: startup creates a minimal `~/.cetas/settings.json` with an onboarding guide, full `--help` output, and credentials shared with Cetas — if you're already logged in elsewhere, just retry your task.

### Fixes
- Reliable process exit codes on both native and wasm builds.

## 0.6.0 (2026-09-29)

## Bun Ver.（cetas-js/cetas-bun）

### Feats
- Rich media attachments are now first-class.
- Compaction and token estimation understand attachments, so context budgeting stays accurate in media-heavy sessions.
- Subagents report detailed background-task exit states, making parallel delegated work easier to trust and debug.
- Provider login is hardened with Node.js crypto-backed UUID generation.
- The lazytools gateway now tracks usage across every terminal tool event for more accurate stats.
- The default permission mode is now `yolo` — fewer approval interruptions out of the box.

### Fixes
- Responses-API providers encode assistant content as `output_text` for maximum compatibility.
- Turn status is correctly restored after running a mid-turn command, and approvals are now scope-honest.
- Image array validation failures no longer surface as spurious protocol errors in the event bridge.
- Permission grants are labeled by scope with an explicit tool-level grant option.

## ACP Ver.（cetas-acp）

### Feats
- Tool outcomes can now carry attachments through the ACP bridge, so editors like Zed receive full-fidelity results.
- Permission requests carry scopes, giving clients finer-grained approval decisions.
- Transient model failures are automatically classified and retried.
- Compaction and token estimation handle messages with attachments.
- The default permission mode is now `yolo`.

### Fixes
- Permission session grants are labeled by scope, with an explicit tool-level grant for precise control.

## Run Ver.（cetas-run）

### Feats
- One-shot session transcripts (JSONL) support media attachments end-to-end.
- Transient model failures are automatically classified and retried, keeping scripted runs resilient.
- Compaction and token estimation account for messages with attachments.
- Delegated work via herdr honors a `parent_yolo` setting, so sub-tasks inherit your autonomy preference.
- The default permission mode is now `yolo`.


## Memoh Ver.（cetas-memoh）

### Feats
- ACP session controls now expose model and reasoning-effort selection, with runtime context-window accounting refreshed when the active model changes.
- `cetas-memoh` is now part of the Cetas release train, with versioned Linux, macOS, and Windows binaries included in release artifacts.

### Fixes
- User cancellations now settle as ACP `cancelled` instead of being reported as application failures.
- Failed session construction now closes the Memoh Tools MCP bridge before returning, avoiding leaked connections during startup failures.

## 0.5.3 (2026-09-27)

## Bun Ver.（cetas-js/cetas-bun）

## ACP Ver.（cetas-acp）

## Run Ver.（cetas-run）

## 0.5.3 (2026-09-27)

## Bun Ver.（cetas-js/cetas-bun）

## ACP Ver.（cetas-acp）

## Run Ver.（cetas-run）

## 0.5.2 (2026-09-27)

## Bun Ver.（cetas-js/cetas-bun）

### Feats
- Plan reviews no longer expire.
- plan results now keep the full plan readable after your decision — expand with ctrl+o to re-read the accepted, revised, or dismissed plan.
- Sessions get stable, metadata-backed automatic titles.

### Fixes
- Plans are saved to disk the moment they are submitted, so a dismissed, failed, or unanswered review still leaves the plan text on file instead of losing it.

## ACP Ver.（cetas-acp）

### Feats
- Session titles advertised to ACP clients are now metadata-backed and stable — user-chosen names take priority, older sessions fall back to a legacy first-message title.
- Plan mode is now a proper write gate: its enter/exit tools bypass the permission prompt, while all other tools keep flowing through the permission policy.

### Fixes
- Plans are saved to disk the moment they are submitted, so a dismissed, failed, or unanswered review still leaves the plan text on file instead of losing it.

## 0.5.1 (2026-09-26)

## Bun Ver.（cetas-bun）

### Feats
- Subagents are now owned by the Bun runtime.

### Fixes
- Child agent tool construction no longer leaks the wrong filesystem.
- Memory extension MCP calls now report detailed, phase-aware failure reasons.

## ACP Ver.（cetas-acp）

### Feats
- Dynamic context window updates.

### Fixes
- The subagent tool is no longer part of the ACP tool catalog.
- Memory extension MCP calls now report detailed, phase-aware failure reasons.

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

## Run Ver.（cetas-run）

### Feats
- cetas-run is now part of the release pipeline and published.
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

## Run Ver.（cetas-run）

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

## Run Ver.（cetas-run）

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

## Run Ver.（cetas-run）

### Feats
- Enhanced JsonlObserver and TraceObserver for improved event streaming
- Enhanced context state management with a new ctx segment
- Cross-platform user home resolution for more reliable configuration paths

### Fixes
- MCP user `mcp.json` path handling on the user level
- More informative webfetch error messages for blocked hosts
- Improved prompt cache key handling for better cache reuse
