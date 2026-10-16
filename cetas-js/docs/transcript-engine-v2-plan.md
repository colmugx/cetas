# Cetas JS Transcript Engine 2.0 — Architecture and Acceptance Contract

Status: implementation plan, not an assertion that any gate is complete.
Base: cetas main at `e964da16b4b2c2a1f913dc91d4d3edb4170dc705`, pi-tui 1.3.0.
Scope: application-owned scrollback, true virtual transcript/list, incremental streaming Markdown, replay/search/selection/overlay/exit correctness. Keep Live Activities and statusbar from PR #90.

## Non-negotiable constraints

1. Session JSONL and MoonBit remain the conversation authority. UI representation is rebuildable, never a second durable conversation database.
2. A message has stable identity and a version; mutable streaming tail and tool output can change their layout without re-rendering unrelated historical messages.
3. Render and layout hot paths must scale with viewport + overscan, **not number of stored messages nor total transcript lines**.
4. Width is measured in terminal display columns; preserve CSI/OSC/Kitty/fake-cursor markers.
5. Rewind/new/resume and session redirect are atomic epoch switches. Pending old-turn timers/events may not repopulate the new viewport.
6. Viewport follow-end and selection/search anchors survive growth, edits, width changes and dynamic-height collapses.
7. Application-owned scrollback must not be dumped in full when leaving the alternate screen.
8. No Agent/protocol changes, no JS fallback release train, and no theme work.

## Architectural choice / upstream constraint

pi-tui 1.3.0 `ScrollView.render()` calls `child.render(contentWidth)`. Its `layout.ts` scroll-node path also renders the entire child to discover `contentHeight`, caches `scrollContentLines`, and uses these lines for search, prompt navigation, image cropping and selection. Merely wrapping the existing `Container` is **not virtualization**.

Make a focused version-pinned pi-tui adapter/fork providing a virtual-document or virtual-scroll layout contract (total logical rows, range render, mapping of row↔item, and invalidation). Prefer a narrow upstreamable abstraction over monkey patching private fields, faking large blank-string arrays, or replacing the input system. Keep rendering final output bounded by terminal width. If the pi-tui contract is insufficient, include the minimal audited library patch in this PR rather than silently dropping search/selection or using a fake viewport.

## Planned modules / ownership

`src/transcript/model.ts`: typed blocks, stable id/revision, append/update/remove/epoch, and unmaterialized replay entries.

`src/transcript/height-index.ts`: Fenwick/prefix-sum tree for cumulative line heights, row→item in O(log N), height changes in O(log N). Unknown-height estimates must be corrected without moving the visible anchor.

`src/transcript/virtual-document.ts`: viewport+overscan range resolution; lazy component creation; bounded mounted component cache; offscreen recycling; preserved message fold and tool states.

`src/transcript/markdown-stream.ts`: completed Markdown blocks become immutable and cacheable by (block id, revision, width, ANSI mode); only the open tail block is reparsed/relaid out on stream flush, with safe fallback for incomplete fences/lists/inline formatting.

`ui/viewport-shell.ts`: AltScreen/ScrollView layout, focus, overlay, editor and Live Activities fixed region; scroll follow/end indicator, mouse hit targets, search and selection adapters, terminal fallback.

`src/transcript/replay-index.ts`: incremental line-indexing and lazy decoding for large JSONL sessions; do not build thousands of terminal components during resume. Preserve wakeup/synthetic-user classification and tool call→result association.

## Ordered commits and gates

### Gate 0: baseline + characterization
- Add deterministic PTY/renderer fixtures, 0/100/1k/10k blocks, small and wide viewports, resize storms, CJK/OSC8/Kitty, thinking/tool fold, delayed events, redraw/heap benchmarks.
- Record current main-screen timings; tests are comparative, avoid claiming unmeasured multipliers.

### Gate 1: pure model + virtual height index
- Stable IDs, immutable replay descriptors, mutable revisions, Fenwick index, range query and anchor model.
- Property tests against a naive reference for random insert/update/remove and offset lookups.

### Gate 2: minimal pi-tui virtual scroll integration
- Formalize virtual scroll node's logical height and visible slice contract; retain exact scroll/scrollbar/mouse semantics.
- Opt in to AltScreen; real render work bounded by viewport + overscan.
- On exit preserve existing main-screen content without printing whole old transcript.

### Gate 3: shell migration
- Use the new store in EventRouter, streaming, replay, rewind/new/resume.
- Fixed header/editor/statusbar layout and stable scrollback, disable legacy per-row O(history) probes when in AltScreen.
- Keep existing public workflows, extension overlays, ask panel, keyboard actions, Live Activities.

### Gate 4: streaming Markdown engine
- Incremental block boundary and tail reparse; bounded cache, invalidation on width/theme environment (no user-facing theme change).
- Keep Markdown tables, fences, links, math, latex and image placeholders parity.

### Gate 5: search, clipboard/selection, accessibility and perf
- Virtual search index; dynamic row-to-message mapping; copy exactly the selected text; stable search highlight and wheel input.
- Performance gates: 10k messages should not have an O(10k) render traversal; no unbounded render cache/mount growth; no terminal width crashes.
- Memory benchmark: after GC, offscreen component mounts bounded; session text/index may remain as needed. Test native memory as well as JS heap where possible.

## Required acceptance scenarios

- Scroll up during streaming: viewport remains anchored until user returns to end.
- Expanded/collapsed tall tool output above the viewport: same message stays pinned.
- Responsive 0/1/8/24/80/200-column widths, 10/20/80-row heights; preserving image placement and cursor.
- Session switch, rewind and redirect while stream timers are pending; never show stale text.
- Modal opens after 10k blocks without rendering entire history twice.
- Search across unmounted blocks and jump to the correct message/line.
- Text selection and copy across message boundaries; no truncation of copied content.
- Preserve existing unit/PTY tests and release build on Bun and Node where supported.

## Explicit out of scope

- Design/theme system (never introduce).
- MoonBit Agent semantics and tool protocol changes.
- New durable transcript format.
- PR #90 Live Activities redesign (already merged).
