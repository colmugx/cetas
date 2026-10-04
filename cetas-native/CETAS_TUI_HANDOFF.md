# Cetas native TUI handoff — rebuilt branch + runnable minimum loop

Date: 2026-10-03  
Repository: `colmugx/cetas`  
PR: #6 — `cetas-tui`

## Goal of this round

This round intentionally narrowed the migration work to three outcomes:

1. rebuild/rebase the long-lived `cetas-tui` branch onto the latest `main`;
2. preserve the existing native migration work while making the smallest real
   application loop something a developer can actually launch and try;
3. leave an exact handoff with current SHAs, run instructions, validation
   state, and known gaps.

This is still a migration branch. It is **not** M7 cutover completion, and
`cetas-js` remains the behavioral oracle.

## Branch rebuild / rebase result

At the start of this round:

- PR head: `c505c1f4ae59d390d7895151f9590f8708615b36`;
- latest `main`: `02370581446583d7ff104c305583c6ca52623ac9`;
- merge base: `41fcc9d43acdb6577c8426548a5cf0226766ec3b`;
- branch state: ahead 18 / behind 24.

A safety branch was created before moving the PR branch:

```text
cetas-tui-pre-rebuild-20261003
```

Do not force-move or delete that branch until the rebuilt branch has had enough
manual testing.

The overlap check between:

- files changed by `main` after the merge base; and
- files changed by `cetas-tui` after the merge base

returned **zero overlapping paths**.

Because there were no file-level conflicts, the branch was rebuilt by:

1. taking the latest `main` tree as the base;
2. replaying every `cetas-tui` file change since the merge base;
3. creating one new parented commit on top of current `main`;
4. force-moving only the `cetas-tui` ref after the backup branch existed.

Rebuild commit:

```text
56fedaa84bba1ad7121683724913143e5766cdf3
rebuild(cetas-tui): replay native TUI work on latest main
```

After the rebuild:

```text
cetas-tui vs main: ahead 1 / behind 0
```

This was a squash-style history rebuild rather than replaying the old migration
commit graph one commit at a time.

## Runnable minimum application loop

The executable entrypoint is:

```text
cetas-native/src/cetas/main.mbt
```

The application path is now:

```text
NativeHost::compose_interactive
        |
        v
Terminal::open_inline
        |
        v
NativeAppLoop
  ├─ NativeTurnDriver
  │    └─ real Posoco Agent turn in a child task
  ├─ NativeRuntime
  │    └─ non-blocking poll / scene render / scrollback flush
  ├─ NativeInputRouter
  ├─ EditorModel
  └─ RewindPickerModel
        |
        v
NativeShellObserver
        |
        v
NativeShell
        |
        ├─ live rows -> inline scene
        └─ finalized rows -> terminal scrollback
```

### What the minimum loop does now

- composes a real Cetas/Posoco native host;
- opens a Ratatui/Crossterm inline terminal;
- renders a MoonBit-owned editor and status line;
- accepts normal text input and paste;
- Enter submits a real Agent turn;
- accepted submission clears the editor and records prompt history;
- Agent work runs in a child task, so terminal polling remains responsive;
- submitting while a turn is active attempts the Agent follow-up queue;
- stale follow-up enqueue races are deferred and restarted after settlement;
- streamed reasoning/text/tool events project into `NativeShell`;
- finalized transcript rows cross once into normal terminal scrollback;
- interactive `UiPort` / permission approval requests are routed through the
  native terminal UI;
- Escape interrupts an active turn;
- idle double-Escape opens persisted rewind selection;
- selecting rewind restores the original user prompt into the editor;
- Ctrl+O updates shell-owned tool-output expansion state;
- Ctrl+C exits;
- shutdown closes UI/terminal state, cancels/drains an active child turn, then
  shuts down the Agent.

The loop uses a cooperative 8 ms sleep between idle ticks.

## Startup usability added in this round

Commit:

```text
7832173b7ae11a61b14bb5b50067f68f24e25aa3
feat(cetas-tui): surface runnable preview controls
```

At startup the native host writes a real finalized transcript/scrollback notice
showing:

- that this is the native Cetas terminal host;
- the current session id;
- Enter = submit;
- Escape = interrupt;
- double-Escape = rewind;
- Ctrl+C = exit.

This avoids launching into an unexplained blank editor.

## How to try it manually

Run from the **repository root**.

Prerequisites:

- MoonBit CLI;
- Rust/Cargo;
- Python 3 for the public-recipe preparation script;
- the same Cetas provider/configuration credentials used by the other hosts.

Recommended commands:

```bash
git switch cetas-tui

# Required once after the old src/main package layout:
moon clean

python3 scripts/prepare-recipe.py --flavor public --frontend native --platform unix
moon update

moon run cetas-native/src/cetas --target native --release
```

Do not run the native host from inside `cetas-native/`. The current development
setup expects root `moon.work` workspace resolution so sibling Cetas packages
are used instead of stale published versions.

Expected first-screen behavior:

1. terminal switches into the inline native UI;
2. a scrollback notice identifies `Cetas 0.7.0`, the active model/effort, and session id;
3. the editor shows a `> ` prompt;
4. status starts as `idle`;
5. type a prompt and press Enter;
6. streamed output should appear live and finalized rows should move into normal
   terminal scrollback.

Useful keys:

```text
Enter        submit
Shift+Enter  newline
Esc          interrupt active turn
Esc, Esc     rewind while idle
Ctrl+O       toggle tool-output expansion state
Ctrl+C       exit / restore terminal
```

Tab currently reaches the application-loop autocomplete signal but does not yet
have a native completion presentation flow.

## Validation state

The rebuilt/runnable code commit `7832173b` passed the dedicated native
validation workflow:

```text
GitHub Actions run: 37119407985

PASS  Prepare native public recipe
PASS  Resolve MoonBit workspace dependencies
PASS  Rust tests
PASS  MoonBit native check --deny-warn
PASS  MoonBit native app tests
PASS  cetas-core rewind parity tests
PASS  Build interactive native Cetas terminal host
PASS  Shared semantic parity fixtures
PASS  FFI + PTY inline smoke test
```

The important point for manual testing is that the actual
`cetas-native/src/cetas` executable successfully builds on the rebuilt branch
against the latest-main workspace, and terminal mechanics still pass the PTY
smoke.

The repository-wide `cetas ci` run triggered for the same code commit was
still executing when this handoff was authored. At that point all recipe/check
stages before the full native test suite had passed. Check the latest PR status
before merging; the dedicated native gate above is the authoritative validation
for the TUI loop itself.

## Existing semantic coverage carried through the rebuild

The rebuilt branch preserves the native migration work accumulated before this
round, including:

- fixed-width/versioned native event ABI;
- Rust staticlib terminal renderer/input/inline-scrollback substrate;
- editor buffer/cursor/history and autocomplete reducers;
- key release filtering and normalized chords;
- overlay/select/rewind reducers;
- transcript live/final ownership;
- assistant reasoning/text streaming and `message_end` deduplication;
- streamed tool identity/adoption;
- queued follow-up transcript promotion;
- ordinary failure parity with the JS EventRouter;
- requested-interrupt termination handling;
- command-lock semantics;
- session redirect adoption;
- deferred-tool parity;
- physical JSONL-line-preserving rewind points;
- typed Posoco observer -> `NativeShell` production path;
- interactive native `UiPort` / approval composition;
- parity fixtures and PTY lifecycle coverage.

## What is deliberately still incomplete

The preview is runnable, but it is not yet the complete product TUI.

### Immediate user-visible gaps

- Tab/autocomplete has reducer behavior but no native completion UI;
- Ctrl+T thinking presentation toggle is surfaced but not wired;
- Ctrl+O state exists, but rich tool-output presentation is incomplete;
- Markdown rendering is still minimal;
- bespoke tool renderers are not fully ported;
- model/provider/session/skills pickers are incomplete;
- OAuth/auth application flows are incomplete;
- extension widgets/render/request parity is incomplete;
- some slash-command/application surfaces still live only in the JS host.

### Release/cutover gaps

- M0 systematic parity fixture freeze is incomplete;
- M2–M6 still have open parity/application-flow work;
- M7 end-to-end host parity is not complete;
- macOS and Windows native runtime/link CI are still required;
- distribution still uses the temporary local Cargo prebuild rather than
  checksum-pinned prebuilt native libraries.

Do not remove `cetas-js` yet.

## Manual smoke sequence to run next

Before broadening the implementation, manually exercise this exact sequence
with a real configured provider:

1. launch the native host;
2. submit one normal prompt;
3. observe streaming text and finalized scrollback;
4. run a prompt that invokes a tool;
5. exercise a permission approval request;
6. submit a follow-up while the first turn is still running;
7. press Escape during an active turn;
8. submit at least two prompts, then use idle double-Escape rewind;
9. press Ctrl+C and verify the terminal restores cleanly;
10. rerun after a failed provider/model request and verify the terminal still
    restores and the shell returns to idle.

Fix defects found by that sequence before adding more modal/product breadth.

## Recommended next implementation target

After the manual smoke sequence is stable, wire `LoopAutocomplete`
end-to-end.

Why this next:

- the reducer semantics already exist;
- the loop already surfaces the signal;
- Tab is a normal-path interaction users will hit immediately;
- it is a contained next step compared with model/auth/extension flows.

After autocomplete, continue M5/M6 application flows based on parity fixtures.

## Recovery / branch references

Current rebuilt base:

```text
main@02370581446583d7ff104c305583c6ca52623ac9
```

Pre-rebuild safety branch:

```text
cetas-tui-pre-rebuild-20261003
```

Pre-rebuild PR head:

```text
c505c1f4ae59d390d7895151f9590f8708615b36
```

Rebuilt branch root commit:

```text
56fedaa84bba1ad7121683724913143e5766cdf3
```

Runnable-preview UX commit:

```text
7832173b7ae11a61b14bb5b50067f68f24e25aa3
```

If behavior appears lost after the rebuild, compare against the safety branch;
do not rewrite the backup ref.

## Files to read first next time

```text
cetas-native/src/cetas/main.mbt
cetas-native/src/app/app_loop.mbt
cetas-native/src/app/turn_driver.mbt
cetas-native/src/app/runtime.mbt
cetas-native/src/app/host.mbt
cetas-native/src/app/observer.mbt
cetas-native/src/app/input.mbt
cetas-native/src/ui/transcript.mbt
cetas-native/CETAS_TUI_MIGRATION.md
cetas-native/README.md
.github/workflows/cetas-tui-validation.yml
```

## Bottom line

The branch has been rebuilt cleanly onto current `main`, the old branch state
is preserved, the native Cetas terminal host executable builds and passes the full
dedicated native validation gate, and the minimum loop is ready for a developer
to try with a real configured provider.

Treat the next phase as **manual product-loop stabilization**, not broad feature
migration.
