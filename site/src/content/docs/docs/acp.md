---
title: ACP / Zed
description: Drive the same Cetas agent through an ACP-compatible editor such as Zed.
---

`cetas-acp` exposes Cetas through the Agent Client Protocol. It composes the same Cetas core used by the other surfaces.

## Build

```bash
cd cetas-acp
moon build --target native --release
```

The native binary is produced at the workspace build output for `colmugx/cetas-acp/main/main.exe`.

## Zed configuration

Launch the binary from the project root so tools inherit the editor-spawned working directory. Register it as an external ACP agent in Zed using the schema from Zed's current external-agent documentation, with an absolute path to the built executable.

```json
{
  "agent": {
    "acp_agents": {
      "cetas": {
        "command": "/absolute/path/to/cetas/_build/native/release/build/colmugx/cetas-acp/main/main.exe",
        "args": []
      }
    }
  }
}
```

## Session configuration

ACP advertises session config options for:

- `model` — persisted as the next launch's selection.
- `effort` — persisted when the active model exposes reasoning-effort choices.
- `permission` — runtime-only and session-scoped; it is deliberately not persisted.

The permission choices are `readonly`, `workspace_write`, `interactive`, and `yolo`. The default posture is `workspace_write` unless configured otherwise.

A model provider must already be configured before the ACP host can serve prompts.
