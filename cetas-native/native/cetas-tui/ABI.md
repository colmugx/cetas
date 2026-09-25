# cetas-tui C ABI v2

This document is the compatibility contract between MoonBit and
`native/cetas-tui`. Rust implementation details and Ratatui types are not part
of the ABI.

## Ownership

- `CetasTui*` is an opaque native handle created by `ctui_open_inline` and
  released exactly once by `ctui_close`.
- Buffers passed from MoonBit to Rust are borrowed for the duration of the call
  only. Rust must never retain pointers into MoonBit-managed memory.
- Variable event payloads (currently paste text) are copied into storage owned
  by the `CetasTui` context. MoonBit reads the length and copies the payload
  into caller-owned memory.
- Scene command/style/text buffers are immutable for the duration of
  `ctui_render_scene`.

## Status codes

| Value | Name | Meaning |
| ---: | --- | --- |
| 0 | `OK` | Operation completed. |
| 1 | `TIMEOUT` | Poll timeout; no event was decoded. |
| 2 | `INVALID_ARGUMENT` | Null handle/buffer or otherwise invalid call input. |
| 3 | `TERMINAL_ERROR` | Crossterm/Ratatui terminal operation failed. |
| 4 | `BUFFER_TOO_SMALL` | Caller-owned output buffer lacks capacity. |
| 5 | `MALFORMED_COMMAND` | Scene command/style/text data failed validation. |

Unknown non-zero values must be treated as errors by MoonBit.

## Terminal lifecycle

`ctui_open_inline(rows)` owns raw terminal setup for a Ratatui
`Viewport::Inline` region. Rows are clamped to `1..=65535`.

On open/resume the backend enables:

- bracketed paste reporting;
- focus change reporting.

`ctui_suspend` disables those event modes and restores the process terminal so
an interactive child process can own it. While suspended, render, poll and
viewport operations return `TERMINAL_ERROR`.

`ctui_resume` recreates the same inline viewport and re-enables event modes.
Suspend and resume are individually idempotent.

`ctui_close` restores the terminal when the context is active; closing a
suspended context does not re-enter raw mode.

## Event words

MoonBit consumes events through `ctui_poll_words`, not by depending on the
native C struct layout.

Each event is exactly 14 little conceptual `uint32_t` words:

| Index | Field |
| ---: | --- |
| 0 | ABI version |
| 1 | native event struct size |
| 2 | event kind |
| 3 | key code |
| 4 | Unicode codepoint for character keys |
| 5 | modifier bitset |
| 6 | key action |
| 7 | width for resize |
| 8 | height for resize |
| 9 | mouse x |
| 10 | mouse y |
| 11 | mouse kind |
| 12 | mouse button |
| 13 | variable text byte length |

Event kinds:

- 0 none
- 1 key
- 2 resize
- 3 mouse
- 4 paste
- 5 focus in
- 6 focus out

Key action:

- 1 press
- 2 repeat
- 3 release

Modifier bits:

- bit 0 shift
- bit 1 control
- bit 2 alt
- bit 3 super
- bit 4 hyper
- bit 5 meta

Paste bytes remain valid in the native context until the next poll call or
close.

## Scene command buffer

A scene contains three buffers:

1. command words (`uint32_t[]`);
2. style words (`uint32_t[]`);
3. UTF-8 text bytes.

One render call validates the complete scene before drawing it.

Each command occupies exactly 8 words:

| Index | Meaning |
| ---: | --- |
| 0 | command kind |
| 1 | x |
| 2 | y |
| 3 | width |
| 4 | height |
| 5 | text offset |
| 6 | text length |
| 7 | style reference / command flags |

Command kinds currently defined:

- 1 text
- 2 clear
- 3 cursor
- 4 bordered block

Coordinates and dimensions must fit `u16`. Text ranges must be in bounds and
valid UTF-8. Unknown command kinds are rejected.

Drawing order is command order; later commands form higher visual layers.

## Style table

Each style occupies exactly 4 words:

| Index | Meaning |
| ---: | --- |
| 0 | foreground color |
| 1 | background color |
| 2 | modifier bitset |
| 3 | reserved, must be zero |

A command style reference of 0 means the default Ratatui style. Non-zero style
references are one-based indexes into the style table.

Color encoding uses the high nibble as a tag:

- `0x0.......` inherit/default field (payload must be zero);
- `0x1.......` reset (payload must be zero);
- `0x2.......` indexed color, low 8 bits are the palette index;
- `0x3.RRGGBB` RGB color.

Modifier bits currently map to Ratatui:

- bit 0 bold
- bit 1 dim
- bit 2 italic
- bit 3 underlined
- bit 4 slow blink
- bit 5 rapid blink
- bit 6 reversed
- bit 7 hidden
- bit 8 crossed out

Unknown modifier bits are rejected.

## Inline transcript model

Mutable UI is rendered inside the inline viewport. Immutable finalized
transcript output is inserted before the viewport with
`ctui_insert_before_text`, which allows normal terminal scrollback to own
history while the live editor/status/streaming region remains redrawable.

Only finalized rows should cross the insert-before boundary.

## Compatibility rules

- `ctui_abi_version()` returns 2 for this contract.
- New command/event/status values may be added without changing existing
  numeric meanings.
- Existing word layouts must not be changed under ABI v2.
- A layout change requires a new ABI version.
- Reserved words/bits must be zero until assigned by a later compatible
  extension.
