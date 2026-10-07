# Cetas GPUI

Native Apple Silicon desktop proof-of-concept for Cetas.

This is a full-path integration:

```text
GPUI/Rust process main
       │
       ├── native window / text / input / MessageScroller
       │
       └── dedicated Cetas core thread
                    │
          MoonBit compiler-generated C
                    │
             real cetas-core
                    │
       providers / sessions / tools / streaming
```

There is no WebView, subprocess, sidecar, or `cetas-run` bridge.

## Build

Requirements: Apple Silicon macOS, Rust/Cargo, MoonBit, Python 3 and Xcode command-line tools.

```bash
cargo build --manifest-path cetas-gpui/Cargo.toml --release --target aarch64-apple-darwin
./cetas-gpui/target/aarch64-apple-darwin/release/cetas-gpui
```

Cetas uses the existing `~/.cetas` provider configuration and the launch
directory as its workspace.

## Integration shape

The MoonBit package is a real async executable that imports and composes
`cetas-core`. Cargo runs Moon's native build with
`options.link.native.cc = tools/moon_cc_capture.py`. The wrapper lets
intermediate native objects compile normally, intercepts only Moon's final
C-backend link, and records the generated C plus Moon's own runtime/archive
link inputs.

Cargo recompiles that generated C with its executable `main` renamed to
`cetas_mbt_core_main`, links it into the GPUI executable, and invokes it on a
dedicated core thread. The MoonBit code remains the C ABI consumer: it polls
semantic commands and emits semantic events through a tiny Rust-owned queue.
The UI never calls MoonBit functions directly.
