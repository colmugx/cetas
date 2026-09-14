---
title: MCP
description: Configure MCP servers for Cetas.
---

Cetas supports MCP server configuration from two locations:

```text
<cetas-home>/.cetas/mcp.json
<cwd>/.mcp.json
```

The project-local `<cwd>/.mcp.json` takes precedence over the user-level file.

In the ACP host, declared MCP servers connect lazily on the first turn by default. Set `CETAS_MCP_MODE=eager` to connect them at startup instead.

This page intentionally does not invent an MCP JSON schema beyond the behavior established by the current repository source.
