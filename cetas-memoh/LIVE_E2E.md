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
  https://github.com/colmugx/cetas/releases/download/cetas-memoh-v0.1.0/cetas-memoh-linux-x64.tar.gz
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

The harness is a MoonBit script (`scripts/memoh_live_e2e.mbtx`). It resolves its
own dependencies from the registry, but it runs inside the `cetas-memoh` module,
so the workspace bridge has to be prepared first:

```sh
cd cetas-memoh
python3 scripts/bootstrap_workspace.py
moon update
```

Use a Memoh bearer token with access to the configured bot. The API URL must
include Memoh's `/api` prefix.

```sh
export MEMOH_API_URL="https://memoh.example/api"
export MEMOH_TOKEN="..."
export MEMOH_BOT_ID="..."

moon run --target native scripts/memoh_live_e2e.mbtx --
```

The harness speaks exactly one Memoh surface: `GET /bots/{id}/acp-options`,
introduced with session-scoped runtimes in
[felinics/Memoh#1717](https://github.com/felinics/Memoh/pull/1717). Requesting it
makes Memoh start the bot's configured workspace command and open a probe ACP
session on it, so a `200` with a populated option set covers the live ACP
`initialize` and `session/new` round trips. The probe verifies the agent is
`acp`, that model selection is exposed with at least one model, and that
reasoning-effort selection is exposed with at least one value. Probe sessions
are Memoh's to close, so the harness creates nothing durable.

A deployment older than that release answers `404`/`405`: it still exposes the
bot-scoped `/acp-runtimes` API. The harness does not fall back to it — it fails
with the upgrade instruction, because carrying two surfaces would quietly rot
and a preflight against the wrong surface is worse than none.

To exercise live model and reasoning controls:

```sh
moon run --target native scripts/memoh_live_e2e.mbtx -- --exercise-controls
```

This selects a model on a throwaway probe session and checks that the agent
reports it back together with that model's own reasoning efforts.

To verify that two model selections do not bleed into each other:

```sh
moon run --target native scripts/memoh_live_e2e.mbtx -- --exercise-concurrency
```

This fails unless the agent offers at least two models, then reads two different
selections back through the shared runtime and refuses equal answers.

The harness never prints the bearer token: JSON bodies are redacted key by key
(`authorization`, session/runtime tokens, `access_token`, `refresh_token`,
`api_key`, `password`, `secret`), and a non-JSON body is reported as omitted
rather than echoed. `--self-check` runs the redaction, selection and
surface-gate fixtures offline; it is the check CI runs on every change.

## 3. Run from GitHub Actions

A dedicated manual workflow is available as `memoh-live-e2e`. Configure the
repository secret `MEMOH_TOKEN`, then dispatch the workflow with:

- `api_url` — Memoh API base URL including `/api`,
- `bot_id` — an existing bot whose generic ACP command launches `cetas-memoh`,
- optional `project_path`,
- optional model/reasoning and concurrency checks (enabled by default).

The workflow installs the MoonBit toolchain, prepares the workspace bridge and
runs the `.mbtx` harness; ``memoh-ci`` separately runs its ``--self-check``
fixture set on every pull request, so harness regressions fail without needing a
live deployment.

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
- process restart continuity: restart the runtime (or wait out the 30-minute
  idle reap), then continue the same conversation. Memoh must resume the
  existing ACP session rather than prompt "start a new session", and the
  resumed turn must keep the model/effort the picker showed,
- two concurrent conversation sessions using different models after the API-level
  `--exercise-concurrency` preflight has passed,
- **a picker-only session** (Memoh opens one to read model/effort options, with
  no Memoh Tools declaration): opening it must succeed, so the picker is never
  empty. This is the degraded path exercised on purpose,
- **a conversation whose Memoh Tools gateway is unreachable**: the turn must
  still answer, stderr must record `degraded session`, and the model must state
  that platform tools are unavailable instead of claiming an action,
- **setup from the Memoh terminal**: run `cetas-memoh setup` in the container
  shell and confirm it reports `/data/.cetas-memoh` (not `/root/.cetas-memoh`),
  then restart the agent runtime and confirm the model appears.

During the same run:

- inspect `cetas-memoh` stderr/runtime logs for leaked credentials or Memoh
  authorization/session-token headers,
- inspect workspace storage before and after turns/restart and confirm there is
  no Cetas-owned conversation transcript.

Record live evidence and failures on issue #25. Do not mark the live-only items
complete from fake ACP tests or static inspection.
