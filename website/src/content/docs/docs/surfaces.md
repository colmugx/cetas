---
title: Surfaces
description: The current ways to access the same Cetas agent.
---

| Surface | Package | Interaction model |
| --- | --- | --- |
| Terminal | `cetas-js` | Interactive terminal UI |
| ACP / editor | `cetas-acp` | Agent Client Protocol host |
| Headless | `cetas-headless` | One user turn per process over argv/stdin |

All three compose the same `cetas-core` assembly and participate in the same Cetas identity and durable-state conventions.

## What is shared today

Provider configuration, credentials, MCP configuration, persisted model/effort selection, and session storage live under the shared Cetas home.

## What is not claimed yet

The repository explicitly distinguishes shared durable state from continuing one conversation seamlessly across different hosts. Cross-surface session resume is the next piece of the product definition, not a completed capability to advertise today.
