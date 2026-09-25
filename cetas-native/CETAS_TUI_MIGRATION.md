# cetas-tui migration plan

## Status

The native route is validated on Linux and migration is underway:

- Ratatui 0.30.2 builds as a Rust `staticlib`.
- Moon's native prebuild hook builds the static library and injects its link
  flags into `colmugx/cetas-native/src`.
- MoonBit `extern "C"` calls link and execute against that Rust library.
- A protocol-aware PTY harness exercises the real inline viewport, batched
  scene draw, two-line CJK scrollback insertion, suspend/resume, terminal
  restoration, FocusIn, bracketed paste payload copy, key input, and SIGWINCH
  resize through the MoonBit executable.
- Ratatui buffer tests lock wide-cell behavior for CJK text.
- The MoonBit app now has semantic transcript/tool reducers plus a
  `NativeShell` reducer; the existing observer JSON wire can be parsed and
  dispatched without TypeScript.

M1 is complete. M0 remains open because the full cetas-js parity fixture set is
not yet frozen, and the later product-flow phases are still in progress.

## Target architecture

```text
cetas-core
   |
   v
cetas-native (MoonBit)
├── app/        application lifecycle and shell state machine
└── ui/         editor, transcript, overlays, layout, scene/reducers
   |
   | narrow pull/render C ABI
   v
native/cetas-tui (Rust)
├── terminal    raw mode, viewport, cursor, restore/suspend
├── input       normalized key/mouse/paste/focus/resize events
├── renderer    batched scene/command execution
└── inline      durable scrollback insertion
   |
   v
Ratatui + Crossterm
```

The Rust library must not own provider state, agent state, slash-command
semantics, autocomplete policy, transcript semantics, or modal workflow state.
It must never call back into MoonBit. MoonBit drives a pull-based event loop and
pushes render commands.

## Source migration map

| cetas-js source | cetas-tui destination | Rule |
| --- | --- | --- |
| `host.ts` | `cetas-native/src/app/` | Replace Bun/process composition with native MoonBit composition. |
| `ui/terminal-shell.ts` | app shell reducer + `src/ui/*` | Split state machine from rendering before porting behavior. |
| `ui/primitives.ts`, `ui/theme.ts` | `scene.mbt` + style helpers | Lower semantic UI nodes to scene commands; no Ratatui object handles in MoonBit. |
| `src/ui-registry.ts` | `editor.mbt` autocomplete model | Preserve trigger/span/replacement behavior; remove pi-tui provider types. |
| `src/controllers/event-router.ts` | transcript/app reducer | Port as deterministic event -> state transitions. |
| `src/controllers/streaming-ui.ts` | `transcript.mbt` | Preserve streaming replacement/finalization behavior. |
| `src/controllers/tool-streaming.ts` | `transcript.mbt` | Preserve tool-call lifecycle and collapse state. |
| `src/transcript/*` | `transcript.mbt`, `markdown.mbt` | Convert components into semantic transcript rows/spans. |
| picker/session/skills/rewind/oauth/auth overlays | `overlay.mbt` + `select_list.mbt` + app flows | Modal state stays MoonBit-side; renderer only draws layers. |
| `ui/extension-ui.ts` | MoonBit extension UI reducer | Keep the existing provider-neutral render/request wire protocol. |
| `src/tool-renderers/*` | MoonBit semantic tool-row renderer | Port specs/registry before bespoke renderers. |
| `ui/osc133.ts` | terminal/scene escape boundary | Preserve shell-integration markers without leaking them into layout state. |

## Migration phases

### M0 — freeze contracts

Before moving behavior, convert the current JS tests into a parity checklist and
capture golden state transitions for the high-risk flows:

- streaming assistant text and thinking;
- tool start/update/end and collapsed/expanded output;
- queued follow-up prompts during an active turn;
- ESC interrupt and double-ESC rewind;
- command lock and setup states;
- autocomplete replacement semantics;
- model/session/skills/rewind pickers;
- OAuth and auth prompts;
- extension render/request UI;
- status bar and extension widgets.

During M0, harden the native ABI:

- replace architecture-sized fields in public event structs with fixed-width
  integers;
- add explicit ABI version/struct version fields;
- implement caller-owned/two-phase paste payload copying;
- guarantee native code never retains MoonBit-owned buffers after a call;
- distinguish timeout, terminal error, and decoded event in poll results.

**Gate:** existing `cetas-js` tests remain green and native ABI tests cover
ownership and malformed input.

### M1 — scene and terminal loop

Implement a MoonBit `Scene` and a batched render command buffer. The initial
command set only needs:

- text/span/line;
- block/background/border;
- clear region;
- cursor placement;
- clipping/layers.

One frame should cross FFI in one render call (or a small fixed number), rather
than exposing Ratatui widgets one by one.

Implement the native event loop around `ctui_poll` and normalized
Key/Mouse/Resize/Paste/Focus events.

**Gate: COMPLETE (Linux validation).** The PTY smoke covers resize, redraw,
Unicode/CJK output, cursor placement, focus, bracketed paste, key input,
scrollback insertion, and clean suspend/resume/restore. Rust tests cover scene
validation and wide-cell rendering.

### M2 — editor, layout and selection

Port the pure interaction primitives into MoonBit:

- editor buffer/cursor/history;
- submit-disable state;
- key normalization and key matching;
- autocomplete trigger/query/replacement logic;
- select-list navigation/filtering;
- overlay stack/focus;
- layout calculations.

Do not port pi-tui classes. Port behavior from tests.

**Gate:** editor and autocomplete parity tests match the current
`UiRegistry`/Editor behavior, including `@path` and slash completion.

### M3 — transcript and streaming

Port transcript state and reducers:

- user/queued-user rows;
- assistant streaming/final rows;
- thinking blocks;
- tool rows and streaming tool output;
- notices/errors;
- replay/resume rows.

Use the validated inline model:

- finalized transcript rows -> `insert_before` / terminal scrollback;
- currently streaming row, ask UI, status, editor -> live inline viewport.

Only finalized immutable rows are inserted into scrollback.

**Current progress:** assistant reasoning/text step boundaries, message_end
deduplication, stable streamed-tool identity/adoption, live-vs-final transcript
ownership, deterministic plain scrollback lowering, and one-shot
`insert_before` handoff are implemented. The native app also parses the
existing observer JSON wire.

**Gate:** recorded Cetas event streams produce semantically equivalent output
to `cetas-js`; no duplicate rows during finalization/replay.

### M4 — TerminalShell state machine

Split and port `TerminalShell` behavior into a MoonBit shell reducer. Preserve:

- start/setup lifecycle;
- turn state and interruption;
- queued follow-ups;
- command lock;
- session redirect/adoption;
- rate-limit recovery display state;
- thinking/tool expansion toggles;
- shutdown ordering.

At this stage `cetas-js` remains the reference implementation and is not
deleted.

**Current progress:** `NativeShell` now composes transcript and tool-streaming
reducers and handles turn, stream, tool-start/result, failure, and scrollback
lifecycle. Observer JSON dispatch feeds that reducer directly.

**Gate:** the same scripted interaction sequence produces equivalent app
commands and shell state transitions on JS and native hosts.

### M5 — modal/application flows

Port model/provider/session/skill/rewind/OAuth/auth flows. Keep I/O and business
operations behind the existing Cetas application boundary; UI modules own only
presentation state.

**Gate:** every current overlay test has a native equivalent and focus always
returns to the editor after dismissal.

### M6 — extension UI and tool renderers

Port the provider-neutral extension render/request protocol and the tool
renderer registry. Avoid native-specific extension contracts: extensions should
continue emitting the same semantic payloads regardless of JS or native host.

**Gate:** builtin renderers and status/widget/request surfaces have parity
fixtures.

### M7 — host parity and cutover

Build `cetas-native` against `cetas-core` and run end-to-end sessions.

Required parity before making native the primary TUI:

- startup/setup and provider authentication;
- normal/streaming turns;
- tool calls and approvals;
- slash commands and shortcuts;
- queued prompts and interrupts;
- sessions, rewind, skills, model picker;
- extension widgets/requests;
- image mention behavior;
- resize, paste, Unicode/wide characters;
- terminal cleanup after normal exit, error, SIGINT and SIGTERM.

Add macOS and Windows native-link/runtime CI before declaring release parity.
Linux/musl and ARM targets follow the distribution matrix used by Cetas.

## Cutover rule

Do not rewrite `cetas-js` in place. Build `cetas-native` alongside it and
treat JS as a behavioral oracle until M7 passes. Once native parity is proven:

1. make `cetas-native` / `cetas-tui` the primary interactive host;
2. keep `cetas-js` temporarily for regression comparison;
3. remove pi-tui only after one release train with native parity coverage.

## Non-goals for the first migration

- exposing the entire Ratatui API through C ABI;
- implementing Cetas application logic in Rust;
- reverse callbacks from Rust into MoonBit;
- retaining MoonBit pointers in Rust;
- making the first ABI a general-purpose `ratatui.mbt` API.

The general-purpose `ratatui.mbt` MoonCakes package should be extracted from
the proven terminal/scene ABI after Cetas establishes the required semantics.
