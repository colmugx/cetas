---
title: Cetas
description: One Cetas, multiple surfaces.
---

Cetas is a coding agent built on [Posoco](https://github.com/colmugx/posoco), a protocol-first LLM agent framework for MoonBit.

> Wherever you access Cetas, Cetas is there.  
> However you access Cetas, it is the same Cetas.

## One Cetas, multiple surfaces

The repository currently exposes three ways to use the same Cetas assembly:

- **Terminal** through `cetas-js`, the interactive Bun-hosted terminal UI.
- **ACP / editor** through `cetas-acp`, including Zed external-agent integration.
- **Headless** through `cetas-headless`, a one-turn stdio-oriented host.

These are not separate agents. Each surface composes the same `cetas-core` assembly and Posoco `Agent`; the surface owns interaction and host concerns rather than a separate agent loop or identity.

## Shared state today

All surfaces resolve the same Cetas home, normally `~/.cetas/`. That durable state includes provider settings, credentials, MCP configuration, model selection, and session data.

Cross-surface conversation resume is **not** documented as complete today. The repository describes it as the next step beyond the shared identity and shared-state model.

Start with [Installation](/docs/installation/) or read the [Architecture](/docs/architecture/) overview.
