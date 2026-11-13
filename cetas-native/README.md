# Cetas Native — Go/Bubble Tea terminal

**Cetas JS is the recommended terminal. Cetas Native is the optional second implementation.** Native uses Go/Bubble Tea v2 for terminal rendering and MoonBit Cetas/Posoco for the agent runtime. It is released for macOS Apple Silicon, Linux x64 and Windows x64, but does not promise feature parity with JS; Pi/Node/Bun-only integrations and Board workflows remain JS-only.

## Install the Native terminal

| Platform | Package manager | Alternative |
| --- | --- | --- |
| macOS Apple Silicon / Linux x64 | `brew install colmugx/tap/cetas` | [Interactive `install.sh`](../install.sh) / [GitHub Releases](https://github.com/colmugx/cetas/releases) |
| Windows x64 | `scoop bucket add cetas https://github.com/colmugx/scoop-bucket` then `scoop install cetas/cetas` | [Interactive `install.ps1`](../install.ps1) / [GitHub Releases](https://github.com/colmugx/cetas/releases) |

Use the `cetas-v*` release series (Memoh has separate releases). The direct installers display version, system, target location, and file names and ask for confirmation before binary downloads; use `--yes` or PowerShell `-Yes` only for unattended automation. Installer defaults to `~/.local/bin`; package managers use their own managed locations.

Native distributes `cetas`, `cetas-acp`, and `cetas-run`. If you only want ACP for Lody/Zed or Run for one-off tasks, download the independent `cetas-acp-*` or `cetas-run-*` archive instead of the full terminal. Those files remain separate GitHub Release assets.

Windows `cetas-windows-x64.zip` additionally contains `cetas_moon.dll`. **Keep the DLL beside `cetas.exe`.** Scoop installs the whole ZIP and exposes the three EXEs via shims while leaving the DLL in the same physical version directory.

Both the npm JS host and Native can put a `cetas` command on `PATH`. The first one on `PATH` wins. Check `command -v cetas` on Unix or `Get-Command cetas` in PowerShell before reporting problems. Homebrew and Scoop update their own managed installation; do not point the interactive install scripts at package-manager directories.

## Architecture

```text
Go / Bubble Tea v2 (terminal input, layout, rendering)
     | events / JSON commands
Go Harness (queueing, lifecycle, errors)
     | Unix: cgo + MoonBit static .a
     | Windows: CGO_ENABLED=0 + MSVC cetas_moon.dll
MoonBit ConsoleRuntime (single locked OS-thread owner)
     |
Cetas Core / Posoco (providers, tools, permissions, sessions, turns)
```

The native runtime shares the core and provider configuration with other Cetas entry points, but UI commands and support for session flows can differ. All hosts normally use `~/.cetas/`; for isolated testing set `CETAS_HOME` to an alternate **parent-home directory** (state lives under `$CETAS_HOME/.cetas/`). For careful validation before using live data, see [Alpha-era validation checklist](ALPHA.md).

## Build from source

Requirements: MoonBit CLI, Go version declared by [`go.mod`](go.mod) (currently 1.27.4), and a compatible native C toolchain; on Windows use the MSVC developer environment. Run Moon commands at the repository root so `moon.work` resolves packages.

macOS / Linux:

```sh
moon update
moon build cetas-native/native_bridge --target native --release
mkdir -p cetas-native/go_bridge/lib
cp _build/native/release/build/colmugx/cetas-native/native_bridge/native_bridge.a cetas-native/go_bridge/lib/libcetas_moon.a
cd cetas-native
CGO_ENABLED=1 go test ./...
CGO_ENABLED=1 go build -trimpath -o ../bin/cetas .
```

Windows (PowerShell in an MSVC developer shell, from repository root):

```powershell
moon update
moon build cetas-native/native_bridge --target native --release
./cetas-native/tools/build_windows_dll.ps1 -OutputDir bin
$env:CETAS_NATIVE_DLL = (Resolve-Path ./bin/cetas_moon.dll).Path
$env:CGO_ENABLED = '0'
cd cetas-native
go test ./... -count=1
go build -trimpath -o ../bin/cetas.exe .
```

The DLL builder consumes the fixed MoonBit archive `_build/native/release/build/colmugx/cetas-native/native_bridge/native_bridge.a` (or a `.lib` fallback), linking `host.c` and the MoonBit runtime into `cetas_moon.dll`. `CETAS_NATIVE_DLL` is only needed for `go test` when the executable runs outside the install directory. For production, place DLL and EXE together.

## Native release size profile

All `cetas-native` release and native CI jobs compile MoonBit's generated C,
dependency stubs, and runtime through `tools/moon-cc-wrapper` using
`MOON_CC_WRAPPER`. The wrapper preserves the compiler chosen by Moon and all
of Moon's required flags, appending `-Os -ffunction-sections -fdata-sections`
on Linux/macOS and `/O1 /Gw /GL` with MSVC on Windows. Both use
`MOONBIT_ALLOCATOR=system`; the Windows DLL linker uses
`/LTCG /OPT:REF /OPT:ICF`. The C host's heap diagnostics are
allocator-aware: system builds perform MoonBit cycle collection and report
that mimalloc-specific statistics are unavailable. Only explicit mimalloc
builds should enable `CETAS_USE_MIMALLOC=1` in the C host (via
`CGO_CFLAGS=-DCETAS_USE_MIMALLOC=1` on Unix, or by setting
`MOONBIT_ALLOCATOR=mimalloc` when invoking the Windows DLL link script).
Never mix the system MoonBit archive with a mimalloc-enabled C host. Standard-library imports are retained because
the native application requires the MoonBit core runtime and modules.
Windows keeps the complete archive in the DLL to preserve callback and
initialization symbols. Go Release builds use `-trimpath -ldflags="-s -w"`;
CI Go tests keep symbols.

This setting prioritizes native footprint; `-Os` and `/O1` can alter
hot-path performance compared with `-O2`, so changes should be checked
against real interactive workloads before release. No compression postprocessor
or unsafe compiler flags are used.
