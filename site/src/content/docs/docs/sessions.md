---
title: Sessions
description: Session storage and the current resume boundary in Cetas.
---

Cetas keeps session data under the shared Cetas durable-state root. The core exposes a `sessions/` location used by its session storage and companion metadata.

The headless surface supports explicit same-surface resume: each fresh invocation creates a session id, and a later invocation can pass `--session <id>` to continue it.

The terminal and ACP hosts also use session storage, but the repository does **not** claim that an arbitrary conversation can already move seamlessly from one surface to another. Treat cross-host session resume as planned behavior until source and tests establish it as a supported contract.
