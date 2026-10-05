# cetas-js pi-tui capability parity map

This file is the implementation checklist for replacing the pi-tui adapter with the
native Ratatui host. It is based on imports used by the current `cetas-js`
production UI, not on pi-tui's entire API.

## Reference applications

These projects are useful implementation references because they exercise the same
classes of terminal behavior Cetas needs:

- **OpenAI Codex** — Ratatui 0.30.2 agent TUI with inline scrollback and streaming Markdown; closest product reference.
- **Yazi** — high-frequency terminal rendering, wide Unicode, componentized widgets,
  and current `ratatui-core` / `ratatui-widgets` usage.
- **GitUI** — Ratatui 0.30, multi-pane application state, overlays, keyboard routing,
  and `ratatui-textarea` for editor behavior.
- **Television** — Ratatui 0.30 fuzzy finder; useful for model/session/skills/file
  selection.
- **bottom** — mature cross-platform Ratatui terminal lifecycle, resize, rendering,
  and release behavior.

The native host should copy proven interaction patterns, not their application
architecture. MoonBit remains the owner of Cetas application state; Rust/Ratatui is
the terminal presentation boundary.

## Exact production dependency inventory

The current `cetas-js` production TypeScript imports **31 unique symbols** from
`@earendil-works/pi-tui@^0.85.1`. This is the migration boundary; native Cetas
does not need to reproduce the rest of pi-tui.

| Ecosystem role | Actual pi-tui symbols |
| --- | --- |
| terminal/runtime | `ProcessTerminal`, `Terminal`, `TUI`, `TuiMainScreen` |
| render composition | `Component`, `Container`, `Box`, `Spacer` |
| text/rich output | `Text`, `Markdown`, `MarkdownTheme`, `Loader` |
| editing/input | `Editor`, `EditorTheme`, `Input` |
| autocomplete | `AutocompleteProvider`, `AutocompleteItem`, `AutocompleteSuggestions` |
| selection | `SelectList`, `SelectItem`, `SelectListTheme`, `fuzzyFilter` |
| overlays | `OverlayHandle`, `OverlayOptions` |
| keyboard helpers | `KeyId`, `matchesKey`, `isKeyRelease`, `getKeybindings` |
| terminal-width/text helpers | `visibleWidth`, `truncateToWidth`, `stripTerminalSequences` |

The 31-symbol count is taken from production imports only; tests and documentation
are excluded. Several symbols are type/protocol shapes rather than widgets, so the
native implementation should preserve their behavior at the MoonBit boundary
instead of creating one Rust type per pi-tui type.

## Actual pi-tui surface used by cetas-js

### Terminal lifecycle and composition

| pi-tui surface | cetas-js use | native/Ratatui replacement | Status |
| --- | --- | --- | --- |
| `ProcessTerminal`, `Terminal` | raw terminal ownership and recovery | Crossterm + Ratatui `DefaultTerminal` | implemented |
| `TUI`, `TuiMainScreen` | render loop, focus, children, overlays | `NativeRuntime` + `Scene` + inline viewport | partial |
| `Component` | common renderable contract | semantic MoonBit models lowered to scene commands | partial |

### Basic presentation

| pi-tui surface | native/Ratatui replacement | Status |
| --- | --- | --- |
| `Text` | `Paragraph`, `Text`, `Line`, `Span` | partial |
| `Container` | explicit layout/composition in MoonBit + Ratatui render pass | partial |
| `Box` | Ratatui `Block` + padding/border | partial |
| `Spacer` | Ratatui `Layout` / reserved rows | partial |
| `Markdown` | `tui-markdown` -> Ratatui `Text` | live + finalized assistant output implemented |
| `Loader` | native status model + spinner glyph/tick presentation | partial |

### Editor and autocomplete

| pi-tui surface | native/Ratatui replacement | Status |
| --- | --- | --- |
| `Editor`, `EditorTheme` | MoonBit `EditorModel`; Ratatui paragraph/editor rendering | partial |
| `Input` | MoonBit input model + Ratatui text field presentation | partial |
| `AutocompleteProvider`, `AutocompleteItem`, `AutocompleteSuggestions` | MoonBit completion protocol + popup `List` | implemented for slash, skill and workspace-file sources |
| history/cursor/multiline editing | `EditorModel` | implemented |
| completion popup | Ratatui `List` / `ListState` presentation | implemented for commands, model/effort, skills, sessions and `@file` |

`ratatui-textarea` is a useful behavioral reference (and is used by GitUI), but
Cetas should not hand editor ownership to Rust because command policy, history and
autocomplete semantics already live in MoonBit.

### Selection and overlays

| pi-tui surface | native/Ratatui replacement | Status |
| --- | --- | --- |
| `SelectList`, `SelectItem`, `SelectListTheme` | Ratatui `List`, `ListState` (shared scene primitive) | implemented for rewind, UiRequest, autocomplete, model/effort, skills and sessions |
| `OverlayHandle`, `OverlayOptions` | MoonBit overlay stack + Ratatui `Clear` / `Block` | partial |
| modal veil/mask | style base scene dim + centered `Clear` / `Block` | todo |
| `fuzzyFilter` | shared deterministic fuzzy matcher used by all native pickers | todo |

The same native select primitive should back model, provider, session, skills,
rewind and file/autocomplete pickers.

### Keyboard and terminal-width helpers

| pi-tui surface | native/Ratatui replacement | Status |
| --- | --- | --- |
| `matchesKey`, `KeyId`, `getKeybindings` | normalized `TerminalEvent` + MoonBit key matcher | mostly implemented |
| `isKeyRelease` | Crossterm key-kind normalization | implemented |
| `visibleWidth`, `truncateToWidth` | Ratatui buffer/cell width or `unicode-width` at Rust boundary | partial |
| `stripTerminalSequences` | avoid ANSI in semantic state; sanitize only at terminal boundary | partial |

### Product surfaces built from those primitives

These are not separate terminal primitives. They must be reproduced with the
common primitives above:

- transcript assistant/reasoning rows;
- tool call/result rows and ctrl+o expansion;
- permission / `UiRequest` asks;
- model/provider/effort picker;
- OAuth progress and auth secret/select prompts;
- sessions / skills / rewind selectors;
- extension status, statusbar, notices and widgets;
- subagent status header;
- slash/file/skill autocomplete;
- command status and loader;
- image/file mention presentation.

## Cutover order

### Gate A — one complete normal query

Automated coverage already drives an editor query through a real Posoco `Agent`
with `ScriptedModel`, settles the child turn, and verifies both user and assistant
rows cross the immutable scrollback boundary. The remaining manual check is
deliberately a real-provider / real-terminal dogfood check, not a mocked substitute.


- [x] terminal opens/restores
- [x] editor accepts a query
- [x] query reaches a real Posoco Agent turn
- [x] streaming assistant state reaches the native transcript
- [x] editor/status rows stay reserved while answer streams
- [x] finalized answer crosses once into terminal scrollback
- [x] finalized output wraps to terminal width
- [x] finalized assistant Markdown is rendered semantically rather than printed raw
- [x] streaming Markdown uses the same semantic renderer
- [ ] manual real-provider PTY smoke is recorded

### Gate B — daily-use input/output parity

**Status: COMPLETE for the Linux native validation target.** Gate B is backed by
product-level contract tests plus the full native FFI/PTY validation job; visual
parity with the pi-tui overlays is intentionally not required.

- [x] autocomplete popup — shared Ratatui `List` handles slash commands, command arguments, `$skill`, and `@file`
- [x] slash commands used by normal sessions — extension `CommandPort` commands plus native `/new`, `/sessions`, `/resume`, `/rewind`, `/compact`, and `/exit`
- [x] model/effort picker — the live Router catalog lowers model × advertised-effort choices to executable `/model <slot> [effort]` selections
- [x] sessions picker — persisted session catalog lowers to executable `/resume <id>` selections; first-run empty state is human-readable
- [x] usable tool call/result renderer — stable tool identity, streamed argument adoption, success/error result rows, collapsed previews and expanded output
- [x] thinking/tool expansion presentation — Ctrl+T and Ctrl+O drive persistent MoonBit-owned presentation state
- [x] file mention picker — workspace index + deterministic ranking insert ordinary `@path` mentions for Agent/read-tool handling

The dedicated `gate_b_wbtest.mbt` contract prevents these daily-use surfaces
from silently regressing. Image mentions remain a richer attachment feature and
are not part of the ordinary-file Gate B contract.

### Gate C — setup and extension parity

**Status: COMPLETE for the Linux native validation target.** The native host can
remain alive before an Agent is composable, repair provider authentication in
place, then recompose the working session without falling back to the JS TUI.

- [x] login provider/method selection — first-run and ready-state `/login` share the provider-neutral core login flow
- [x] secret/auth prompts — native UiRequest input/select surfaces include masked secret presentation and cancellation
- [x] OAuth progress overlay — URL, device-code and progress interactions render through keyed native notice/status mounts
- [x] extension render mounts — keyed Status/Notice/Widget `UiRender` intents are retained and replaced through `NativeUiRenderModel`
- [x] extension requests — Input/SecretInput/Confirm/Select requests stay focused inside the Ratatui loop and return through `NativeUiPort`
- [x] extension widgets/statusbar — native composes the shared EventBus with Router, Stats and StatusBar; status/widget mounts render through the same UI protocol
- [x] subagent presentation — native composes the Cetas child-agent capability and projects typed child activity into keyed widget mounts

`gate_c_wbtest.mbt` locks setup recovery, keyed extension mounts, UiRequest
round-trips, secret masking, OAuth presentation and subagent activity semantics.
The full Linux native validation covers executable build, interface drift,
semantic fixtures and FFI/PTY smoke.

Background `agent(..., background=true)` still needs an app-lifetime
`Agent::run_scoped` owner in the native host. Foreground delegation (the default)
and Gate C's subagent presentation are complete; background lifetime support is a
post-Gate-C parity item rather than a setup/auth/UI blocker.

### Gate D — default-host cutover

- [ ] macOS native runtime CI
- [ ] Windows native runtime CI
- [ ] packaged prebuilt native library flow
- [ ] end-to-end parity corpus
- [ ] one release train with JS retained as fallback
