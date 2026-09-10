---
title: Quick Start
description: Get a repository checkout ready to run Cetas.
---

## Prerequisites

You need the [MoonBit toolchain](https://docs.moonbitlang.com). The interactive `cetas-js` host also uses [Bun](https://bun.sh).

The repository is designed to build in the Posoco workspace. If you are developing from source, keep the Cetas checkout in the workspace shape expected by the repository so MoonBit dependencies resolve consistently.

## Configure a provider

A model provider must be configured before Cetas can serve prompts. Cetas stores provider configuration under the shared Cetas home, normally:

```text
~/.cetas/settings.json
```

Provider-specific endpoint, credential, protocol, and model semantics belong to the provider extensions. Cetas passes provider settings to those extensions rather than interpreting every provider schema itself.

Use the interactive Cetas login/model flows when available instead of inventing provider JSON fields. See [Providers](/docs/configuration/providers/) and [Models](/docs/configuration/models/).

## Start a surface

For the terminal host from a source checkout:

```bash
cd cetas-js
bun install
bun run start
```

For editor integration, continue with [ACP / Zed](/docs/acp/). For automation and one-shot invocations, see [Headless](/docs/headless/).
