# Cetas GPUI POC

Native macOS ARM64 proof-of-concept for running the real MoonBit Cetas core in
the same process as a GPUI Kit desktop surface.

The build deliberately does not use `cetas-run`, a subprocess, WebView, or a
mock agent. MoonBit is built with the C backend, the final compiler invocation
is intercepted, and those generated C sources are linked into the Rust/GPUI
binary. Rust starts the renamed MoonBit executable entry on a dedicated thread.

The bridge direction stays inside MoonBit's stable C-FFI use case:

- MoonBit pulls JSON commands from Rust with `extern "C"`.
- MoonBit pushes semantic turn/stream/tool events to Rust with `extern "C"`.
- Rust never calls a MoonBit callback or relies on a MoonBit data-layout ABI.

## Build on Apple Silicon

```bash
python3 cetas-gpui/tools/build.py --target aarch64-apple-darwin
./cetas-gpui/target/aarch64-apple-darwin/release/cetas-gpui
```

The app reads the same `~/.cetas` provider configuration as other Cetas
surfaces. The first POC composes directly from `cetas-core`; the full compiled
tool recipe is intentionally the next layer after this in-process runtime seam
is proven.
