---
title: Headless
description: Run one Cetas turn per process with a stable stdio-oriented interface.
---

`cetas-headless` is the one-shot surface: one process invocation runs exactly one user turn. It reuses `cetas-core`; the package is a host shell rather than a second agent implementation.

## Command shape

```text
cetas-headless [--model <id>] [--effort <level>] [--session <id>]
               [--yolo | --permission <readonly|workspace_write|interactive>]
               [--stream] [--verbose] [--show-thinking] [--jsonl]
               [-- "<task>"]
```

Pass the task after `--`. If no task is present in argv, Cetas reads exactly one line from stdin.

## Sessions

Without `--session`, the process creates a fresh session id and reports it on stderr. Re-run with `--session <id>` to continue that headless session.

This same-host resume behavior does not imply cross-surface resume. Cross-host continuation is still described by the repository as future work.

## Output contract

In text modes, stdout is answer-only. `--stream` emits answer deltas as they arrive. `--verbose` and `--show-thinking` route diagnostics/reasoning to stderr.

`--jsonl` changes stdout into the structured event stream and takes precedence over the text output modes.

## Permissions

`--permission` accepts `readonly`, `workspace_write`, or `interactive`. `--yolo` is the unattended mode and cannot be combined with `--permission`.

## Exit codes

- `0`: the turn completed.
- `1`: the turn ran but failed.
- `2`: startup or usage failure, including invalid CLI/model/effort configuration.
