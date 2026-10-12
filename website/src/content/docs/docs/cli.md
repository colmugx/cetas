---
title: CLI
description: Use Cetas from its interactive terminal surface.
---

`cetas-js` is the interactive terminal surface. Its process entry point constructs the Cetas application and a terminal shell around the shared agent bridge.

## Run from source

```bash
cd cetas-js
bun install
bun run start
```

The project also provides `bun run build` to produce compiled `cetas-bun-*` executables.

## Shared model selection

The terminal surface participates in the shared model-selection contract. Successful `/model` and `/effort` changes are persisted to `~/.cetas/settings.json`, so a later Cetas launch can use the same selection.

## Provider login

Provider discovery, `/model`, and `/login` are built from the same registered provider factory set. This keeps the terminal surface aligned with the providers that Cetas can actually compose.

For non-interactive single-turn usage, use [Headless](/docs/headless/) instead of scripting terminal UI output.
