# cetas-native / cetas-tui validation

This branch validates the native TUI boundary before any migration from `cetas-js`.

- MoonBit owns application state and UI semantics.
- `native/cetas-tui` owns terminal mechanics behind a narrow C ABI.
- Rust uses Ratatui + Crossterm.
- The terminal model is an inline viewport plus `insert_before`, so finalized
  transcript output can become normal terminal scrollback while the mutable UI
  remains live below it.

For validation, Moon's prebuild hook invokes Cargo locally. This is deliberately
temporary. A future MoonCakes package should consume checksum-pinned prebuilt
static libraries so downstream applications do not require Rust.
