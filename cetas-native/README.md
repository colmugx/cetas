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

## Product scope and Alpha

`cetas-native` is a separate product frontend for the shared Cetas/Posoco
Agent. It does **not** aim for feature parity with `cetas-js`. Pi and other
Node/Bun-only integrations remain JS-exclusive; Native may have its own
exclusive capabilities later.

**Current status:** Alpha candidate / internal evaluation. The Go/Bubble Tea
build, MoonBit bridge, command system, virtualized transcript and PTY
interaction suite are integrated. Automated tests alone do not prove safe
real-provider operation. First-run onboarding has a dedicated empty-home
PTY test in CI.

Use [ALPHA.md](ALPHA.md) for supported platforms, opt-in downloadable Actions
artifacts, isolated-state instructions, and external Alpha release gates.
Current release.yml does **not** distribute `cetas-native`; production
`cetas-js` remains unaffected.

A public/self-service Alpha requires a passing clean-home setup smoke,
a clean-machine binary installation test, and live provider/session
acceptance. We will prioritize these release blockers over JS parity,
cosmetic enhancements, or platform expansion.
