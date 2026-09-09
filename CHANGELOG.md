# Changelog

Entries in this file are written by `scripts/release.py` at release time, as `## X.Y.Z (YYYY-MM-DD)` sections ordered newest first.

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
