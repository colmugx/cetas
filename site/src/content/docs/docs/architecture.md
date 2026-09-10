---
title: Architecture
description: How Cetas surfaces compose one shared core and Posoco agent.
---

The defining architectural rule is simple: a new Cetas surface is a new way into the same agent, not a separate product identity.

```text
                 Cetas
                   │
       ┌───────────┼───────────┐
       │           │           │
    Terminal      ACP       Headless
       │           │           │
       └───────────┼───────────┘
                   │
              cetas-core
                   │
                Posoco
                   │
            model provider
```

`cetas-core` owns the shared composition concerns: provider assembly, active model selection, Cetas home paths, session assembly, and prompt/agent wiring. Surface packages adapt that assembly to their host environment.

- `cetas-js` provides the Bun process host and terminal UI.
- `cetas-acp` exposes the agent through ACP for editors such as Zed.
- `cetas-headless` exposes one-turn stdio execution for automation.

The surfaces do not each implement an independent agent loop.
