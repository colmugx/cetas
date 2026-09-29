# Live Memoh E2E

This document tracks the **real** Memoh validation path for `cetas-memoh`.
Unit tests and fake ACP fixtures are useful, but they do not satisfy the live
E2E requirement.

## 1. Prepare a real Memoh container workspace

The Memoh generic ACP profile is `acp`. It supports the container backend and
uses two managed fields:

- `command` — required executable name or path.
- `arguments` — optional arguments, one argument per line.

Install the released Linux binary inside the bot workspace. The release archive
contains a single executable named `cetas-memoh`.

For example, from a workspace shell:

```sh
mkdir -p /data/bin
cd /data/bin
curl -fL -o cetas-memoh-linux-x64.tar.gz \
  https://github.com/colmugx/cetas/releases/download/cetas-v0.6.0/cetas-memoh-linux-x64.tar.gz
tar -xzf cetas-memoh-linux-x64.tar.gz
chmod +x cetas-memoh
./cetas-memoh --version
```

Configure the bot's generic ACP Agent with:

```text
profile:   acp
command:   /data/bin/cetas-memoh
arguments: <empty>
```

The bot must also have provider configuration/credentials that let
`cetas-memoh` build at least one model slot.

## 2. Run the live ACP preflight

Use a Memoh bearer token with access to the configured bot. The API URL must
include Memoh's `/api` prefix.

```sh
export MEMOH_API_URL="https://memoh.example/api"
export MEMOH_TOKEN="..."
export MEMOH_BOT_ID="..."

python3 scripts/memoh_live_e2e.py
```

The script creates a temporary **real** ACP runtime through Memoh, which starts
the configured workspace command. For `cetas-memoh`, successful runtime
creation covers the live ACP initialize/session-new path and the Memoh Tools
HTTP MCP connection required while constructing the session. It then verifies:

- the runtime is the generic `acp` agent,
- model selection is exposed with at least one model,
- reasoning-effort selection is exposed with at least one value,
- the runtime can be read back by ID,
- the temporary runtime is closed on exit.

To also exercise Memoh's live model and reasoning control endpoints on that
temporary runtime:

```sh
python3 scripts/memoh_live_e2e.py --exercise-controls
```

To verify cross-session model isolation, start two real runtimes for the same
bot and force them onto two different shared model IDs:

```sh
python3 scripts/memoh_live_e2e.py --exercise-concurrency
```

This mode fails unless both runtimes expose at least two common models. It PATCHes
different model IDs into the two runtimes, reads both statuses back, and fails
if either runtime changed to the other's model. Both temporary runtimes are
deleted on exit unless `--keep-runtime` is supplied.

The harness never prints the bearer token and redacts common authorization,
session-token, access-token, and refresh-token shapes from HTTP error bodies.
It does not modify durable bot configuration.

## 3. Run from GitHub Actions

A dedicated manual workflow is available as `memoh-live-e2e`. Configure the
repository secret `MEMOH_TOKEN`, then dispatch the workflow with:

- `api_url` — Memoh API base URL including `/api`,
- `bot_id` — an existing bot whose generic ACP command launches `cetas-memoh`,
- optional `project_path`,
- optional model/reasoning and concurrency checks (enabled by default).

The workflow uses only the dedicated `memoh-*` path and never runs as part of
the general Cetas CI. GitHub masks the configured secret and the harness also
redacts common credential shapes from HTTP error bodies.

## 4. Finish the UI/tool E2E manually

The preflight above is deliberately not claimed as full E2E. Complete these
scenarios in a real Memoh conversation:

- basic prompt/answer,
- workspace read and edit through Memoh Tools,
- command execution,
- approval UI,
- memory search/create,
- browser/computer on a display-enabled workspace,
- model picker,
- effort picker,
- model switch followed by effective context-window verification,
- cancellation settling as ACP `cancelled`,
- session close,
- process restart continuity,
- two concurrent conversation sessions using different models after the API-level
  `--exercise-concurrency` preflight has passed.

During the same run:

- inspect `cetas-memoh` stderr/runtime logs for leaked credentials or Memoh
  authorization/session-token headers,
- inspect workspace storage before and after turns/restart and confirm there is
  no Cetas-owned conversation transcript.

Record live evidence and failures from the real workspace run. Do not mark the
live-only items complete from fake ACP tests or static inspection.
