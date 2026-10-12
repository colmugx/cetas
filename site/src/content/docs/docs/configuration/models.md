---
title: Models
description: Understand model slots and the shared active model selection.
---

Cetas identifies a model slot using a `provider/model` id.

The shared active selection is persisted as top-level keys in `~/.cetas/settings.json` alongside `providers`:

```json
{
  "providers": {},
  "model": "provider/model",
  "reasoning_effort": "high"
}
```

`reasoning_effort` is optional. If it is absent, the active model's advertised default is used. If a previously selected model is no longer available because provider configuration changed, Cetas falls back to the router's available default rather than failing composition solely because the old selection drifted away.

The interactive terminal persists successful `/model` and `/effort` changes. ACP persists successful model/effort config-option changes. Headless `--model` and `--effort` are run-scoped overrides and are not persisted.
