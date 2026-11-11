# Cetas Native — Go/Bubble Tea migration

This directory is being rebuilt as a single-process Go Bubble Tea v2 terminal host for the existing MoonBit Cetas/Posoco application.

## Design

```
Bubble Tea v2 (Go, owns terminal input, layout and rendering)
     │ commands and event reducer
Go Harness (correlated JSON commands, lifecycle, error propagation)
     │ Unix: cgo + static archive / Windows: pure Go + MSVC DLL
MoonBit ConsoleRuntime (single locked OS-thread owner)
     │
Cetas Core / Posoco (providers, tools, permissions, sessions, turns)
```

The architecture follows [Scena](https://github.com/colmugx/scena)'s native C bridge, **not** the retired Rust Ratatui/Crossterm terminal ABI.

## Development

Prerequisites: MoonBit toolchain, Go 1.26+, Clang, Python 3 (for PTY smoke scripts), and a C compiler toolchain. Start in the repository root so `moon.work` resolves the local packages:

```sh
moon update
moon build cetas-native/native_bridge --target native --release
mkdir -p cetas-native/go_bridge/lib
cp _build/native/release/build/colmugx/cetas-native/native_bridge/native_bridge.a cetas-native/go_bridge/lib/libcetas_moon.a
cd cetas-native
CGO_ENABLED=1 go mod tidy
CGO_ENABLED=1 go test ./...
CGO_ENABLED=1 go run .
```

On Unix, the bridge archive is generated in `go_bridge/lib/` and must not be committed.

Windows uses a separate MSVC DLL workflow. From a VS developer shell in the repository root:

```powershell
moon update
moon build cetas-native/native_bridge --target native --release
./cetas-native/tools/build_windows_dll.ps1 -OutputDir bin
$env:CETAS_NATIVE_DLL = (Resolve-Path ./bin/cetas_moon.dll).Path
$env:CGO_ENABLED = "0"
cd cetas-native
go test ./... -count=1
go build -o ../bin/cetas.exe .
```

`build_windows_dll.ps1` consumes the fixed MoonBit archive at
`_build/native/release/build/colmugx/cetas-native/native_bridge/native_bridge.a`
(with `.lib` fallback) and links `host.c` and the MoonBit runtime through
MSVC into `bin/cetas_moon.dll`. Shipping Windows binaries must include
`cetas.exe` and `cetas_moon.dll` in the **same directory**. The Go
binary uses `CGO_ENABLED=0` and dynamically resolves the DLL's C ABI.
`CETAS_NATIVE_DLL` is only needed for tests whose Go executable lives in
a temporary Go test directory.

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
Release builds produce the native `cetas` binary on Unix and an adjacent
DLL-backed native Windows bundle. These do not replace the JS frontend.

A public/self-service Alpha requires a passing clean-home setup smoke,
a clean-machine binary installation test, and live provider/session
acceptance. We will prioritize these release blockers over JS parity,
cosmetic enhancements, or platform expansion.

## Native release size profile

All `cetas-native` release and native CI jobs compile MoonBit's generated C,
dependency stubs, and runtime through `tools/moon-cc-wrapper` using
`MOON_CC_WRAPPER`. The wrapper preserves the compiler chosen by Moon and all
of Moon's required flags, appending `-Os -ffunction-sections -fdata-sections`
on Linux/macOS and `/O1 /Gw /GL` with MSVC on Windows. Both use
`MOONBIT_ALLOCATOR=system`; the Windows DLL linker uses
`/LTCG /OPT:REF /OPT:ICF`. Standard-library imports are retained because
the native application requires the MoonBit core runtime and modules.
Windows keeps the complete archive in the DLL to preserve callback and
initialization symbols. Go Release builds use `-trimpath -ldflags="-s -w"`;
CI Go tests keep symbols.

This setting prioritizes native footprint; `-Os` and `/O1` can alter
hot-path performance compared with `-O2`, so changes should be checked
against real interactive workloads before release. No compression postprocessor
or unsafe compiler flags are used.
