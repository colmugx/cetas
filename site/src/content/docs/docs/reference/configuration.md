---
title: Configuration Reference
description: Current shared configuration keys and paths used by Cetas.
---

## `settings.json`

Path: `<home>/.cetas/settings.json`.

Known top-level responsibilities in the current core:

| Key | Purpose |
| --- | --- |
| `providers` | Provider-extension configuration. Provider-specific values are interpreted by the extension. |
| `model` | Persisted active router slot id in `provider/model` form. |
| `reasoning_effort` | Optional persisted effort for the selected model. |

Cetas preserves unrelated settings keys when updating the active model selection.

## Other durable paths

| Path | Purpose |
| --- | --- |
| `<home>/.cetas/credentials/` | Provider credentials |
| `<home>/.cetas/model_lists.json` | Model-list cache |
| `<home>/.cetas/mcp.json` | User-level MCP configuration |
| `<home>/.cetas/sessions/` | Session data and companions |
| `<home>/.cetas/debug/` | Debug taps/catalog data |
| `<cwd>/.mcp.json` | Project-local MCP configuration, overriding the user file |
