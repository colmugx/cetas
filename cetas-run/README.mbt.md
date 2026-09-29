# Cetas Run

`cetas-run` is the one-shot, non-interactive Cetas frontend for scripts, CI, agent swarms, and MoonX.

It runs exactly one Cetas user turn per invocation. The task can be supplied after `--` or as one line on stdin. Normal stdout is reserved for the answer; diagnostics, session metadata, approvals, and lifecycle markers use stderr.

## Run from Mooncakes

```bash
moonx colmugx/cetas-run -- --yolo -- "fix the failing tests"
```

Continue a session by passing the emitted session id:

```bash
moonx colmugx/cetas-run -- --session <id> -- "continue"
```

For machine-readable output, use `--jsonl`; add `--stream` for live deltas.

## Targets

The module supports native and Wasm targets. MoonX uses the Wasm build and the host sandbox controls the capabilities available to tools.

## Configuration

Cetas reads provider configuration and credentials from the shared Cetas home (normally `~/.cetas`). `CETAS_HOME` overrides that location.

Repository: https://github.com/colmugx/cetas
