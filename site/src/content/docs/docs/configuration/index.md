---
title: Configuration
description: Understand Cetas configuration and the shared durable-state model.
---

Cetas configuration is shared through the Cetas home, normally `~/.cetas/`.

The central settings file is:

```text
~/.cetas/settings.json
```

It contains provider configuration plus the persisted active model selection. Provider settings are intentionally delegated to provider extensions rather than normalized by Cetas into one universal provider schema.

Related durable state includes credentials, MCP configuration, model-list cache, sessions, and debug data. See [Cetas Home](/docs/configuration/cetas-home/) for the current layout.
