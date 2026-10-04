# cetas-native / cetas-tui

MoonBit owns the native Cetas application/UI state. Rust owns only terminal
mechanics behind the narrow `native/cetas-tui` C ABI using Ratatui + Crossterm.

## Run the native Cetas terminal host

Prerequisites:

- MoonBit CLI
- Rust/Cargo
- the same Cetas provider/configuration you use with the other hosts

From the **repository root** (workspace mode is required):

```bash
# Required once after switching from the old src/main preview layout:
# it removes stale _build artifacts such as main.exe/src.exe.
moon clean

python3 scripts/prepare-recipe.py --flavor public --frontend native --platform unix
moon update
moon run cetas-native/src/cetas --target native --release
```

Do not run the product host from inside `cetas-native/`: current Cetas packages are
developed together in the root `moon.work`, and the native host intentionally
uses those workspace siblings rather than stale published module versions.

The Moon prebuild hook builds the local Rust static library automatically.

The native host currently wires the product loop:

- inline Ratatui terminal startup and cleanup;
- multiline editor input and paste;
- Enter starts a real Posoco/Cetas Agent turn;
- input submitted while a turn is running is queued as a follow-up;
- streamed assistant/thinking/tool state is rendered live;
- finalized rows move once into normal terminal scrollback;
- interactive UiPort/approval requests are handled in the terminal;
- Escape interrupts an active turn;
- idle double-Escape opens persisted rewind selection;
- Ctrl+O toggles the shell-owned tool-output expansion state;
- Ctrl+C exits and restores the terminal.

Still intentionally incomplete in the native host:

- Tab/autocomplete is surfaced by the loop but not yet presented;
- Ctrl+T thinking presentation is not yet wired;
- model/session/skills/OAuth/auth command flows are not yet ported;
- rich Markdown/tool renderers and extension widgets are still parity work.

If startup composition fails, the executable prints the composition error to
stderr and exits with status 2. A terminal/FFI failure exits with status 1.

## Validation

The dedicated `cetas-tui validation` workflow checks:

- Rust staticlib tests;
- MoonBit native `--deny-warn`;
- native app wbtests;
- cetas-core rewind parity tests;
- the native Cetas terminal host build;
- shared semantic parity fixtures;
- a protocol-aware PTY smoke covering inline viewport, scrollback,
  suspend/resume, focus, paste, key input, resize, and terminal restoration.

For now the build hook invokes Cargo locally. A future MoonCakes package should
consume checksum-pinned prebuilt static libraries so downstream applications do
not require Rust.
