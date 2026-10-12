---
title: Environment Variables
description: Environment variables with behavior established by the current Cetas source.
---

| Variable | Scope | Behavior |
| --- | --- | --- |
| `CETAS_HOME` | All hosts | Overrides the base home used to derive the shared `.cetas` durable-state directory. |
| `CETAS_MCP_MODE` | MCP-capable host flow | `eager` requests startup connection of MCP servers instead of the default lazy first-turn connection. |
| `CETAS_PERMISSION_MODE` | ACP | Startup permission mode: `readonly`, `workspace_write`, `interactive`, or `yolo`; invalid values warn and fall back to `workspace_write`. |

Headless model, effort, permission, and yolo behavior is expressed through command-line flags rather than these environment variables.
