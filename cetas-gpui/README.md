# Cetas GPUI — macOS arm64 native POC

**Integration gate:** real `cetas-core` + Posoco via the existing
`cetas-web/server` MoonBit source, **compiled into the same executable**.
No `cetas-run`, no WebView, no mock provider or mock transcript.
GPUI Kit renders all windows, virtual rows, streamed Markdown and text input.

The embedded MoonBit runtime owns the provider/session/agent lifecycle and
publishes the existing `cetas-web/0.1` semantic protocol on loopback.
The Rust GPUI layer is its native UI client *within the same process*.
Loopback here is a temporary internal transport, not an extra process and not
a WebView. It can later be replaced with an in-memory queue without
changing the domain message vocabulary.

## Build

Requires Apple Silicon macOS 15+, Xcode CLT, Rust stable, MoonBit CLI,
and the repository's existing MoonBit workspace/dependency checkouts.

```sh
bash cetas-gpui/scripts/build-macos.sh
open cetas-gpui/dist/Cetas.app
```

The script temporarily selects `link.native.cc` on
`cetas-web/server/moon.pkg`, captures the compiler's `.c` inputs (following
`ai-passport.mbt`'s precedent), restores `moon.pkg`, and compiles the
captured C with Cargo's `cc` build dependency into the GPUI executable.
`MOONBIT_NEW_NATIVE=0` pins the C backend.

The backend uses your existing `~/.cetas` configuration and provider
credentials. The default POC permission is the existing WebRuntime's
`workspace_write`; only run prompts you trust. The UI displays a setup
error if no providers are configured.

### Acceptance

- The `cetas-gpui` executable links the generated C and MoonBit runtime
  (not a separate `cetas-run` binary).
- The native UI shows the real core status and model, accepts user prompts,
  receives incremental reasoning/text and tool events.
- Rows are native GPUI Kit variable-height virtual rows; assistant text
  uses native streamed Markdown rendering and follows the transcript tail.
- CI builds the same source path on macOS arm64 and uploads `Cetas.app`.

### Limitations / active risks

This is a **compile-and-open spike**, not a signed production release.
The embedded C executable entry symbol must be verified against the installed
MoonBit compiler version; the compiler's generated-C / runtime ABI is not a
stable published library ABI. CI intentionally fails on compilation or link
breakage instead of falling back to a subprocess. Currently the real-time
protocol is limited to the Cetas Web observer's v0.1 capabilities.
