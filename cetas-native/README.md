# Cetas Native — Go/Bubble Tea migration

This directory is being rebuilt as a single-process Go Bubble Tea v2 terminal host for the existing MoonBit Cetas/Posoco application.

## Design

```
Bubble Tea v2 (Go, owns terminal input, layout and rendering)
     │ commands and event reducer
Go Harness (correlated JSON commands, lifecycle, error propagation)
     │ cgo / deep-copied bounded C queues
MoonBit ConsoleRuntime (single locked OS-thread owner)
     │
Cetas Core / Posoco (providers, tools, permissions, sessions, turns)
```

The architecture follows [Scena](https://github.com/colmugx/scena)'s native C bridge, **not** the retired Rust Ratatui/Crossterm terminal ABI.

## Development

Prerequisites: MoonBit toolchain, Go 1.26+, Clang, Python 3, C compiler toolchain. Start in the repository root so `moon.work` resolves the local packages:

```sh
moon update
python3 cetas-native/tools/build_static.py
cd cetas-native
CGO_ENABLED=1 go mod tidy
CGO_ENABLED=1 go test ./...
CGO_ENABLED=1 go run .
```

The bridge archive is generated in `go_bridge/lib/`. It must not be committed. The first bridge build targets Darwin/Linux; other targets require tested runtime C stubs and linker flags.

## Migration contract

`cetas-js` is the functional reference. Do not cut over release binaries until all of the following are verified against it: login and OAuth, provider/model/effort selection, sessions and rewind, live streaming with tool/render events, approvals and questions, extension UI mounts, completion, multiline editor, Markdown/diff, queued prompts, scrollback/search, cancellation, startup recovery, and terminal restoration. The native transport must never silently drop events under backpressure.

## Current status

Bridge infrastructure and the initial Bubble Tea terminal model are present. This is **not yet feature parity** with `cetas-js`. A successful Go unit test alone does not establish live MoonBit/Posoco end-to-end correctness. The migration PR must remain draft until interactive PTY and provider smoke tests pass.
