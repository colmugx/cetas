---
title: Providers
description: How provider extensions participate in Cetas composition.
---

Provider configuration lives under `providers` in `~/.cetas/settings.json`. Cetas supplies the settings and credential sources; each provider extension owns its own defaults, endpoints, protocol details, model capabilities, and login behavior.

## Registered providers

The current core registers provider factories for:

- DeepSeek
- Kimi
- OpenAI
- OpenCode Zen
- Z.ai
- Z.ai Coding Plan
- OpenRouter

Additional settings keys can participate through the OpenAI-compatible provider adapter when their provider ids are valid and do not collide with a statically registered provider.

Provider ids are restricted to letters, digits, `_`, and `-` because they are also used in settings, credential filenames, and login targets.

The repository does not define one generic JSON schema for every provider, so this documentation does not fabricate provider-specific keys.
