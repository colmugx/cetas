---
title: Cetas Home
description: Durable state shared by the Cetas terminal, ACP, and headless surfaces.
---

Cetas resolves one home directory for durable state. A non-empty `CETAS_HOME` overrides the platform user home; otherwise Cetas uses the platform home and falls back to the current directory only when no home can be resolved.

The durable-state root is `<home>/.cetas`.

```text
~/.cetas/
├── settings.json
├── credentials/
├── model_lists.json
├── mcp.json
├── sessions/
└── debug/
```

This shared directory is what makes model selection, credentials, MCP configuration, and stored sessions part of the same Cetas identity across surfaces.

Individual hosts can also use project-local configuration where explicitly documented, such as `<cwd>/.mcp.json` overriding the user-level MCP file.
