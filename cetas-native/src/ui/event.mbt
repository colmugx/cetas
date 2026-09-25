/// Stable MoonBit view of one normalized terminal event.
///
/// The native ABI transports events as 14 UInt words. These enums and structs
/// are purely MoonBit-side; their memory layout is never exposed over C FFI.

///|
pub(all) enum TerminalEventKind {
  EventNone
  EventKey
  EventResize
  EventMouse
  EventPaste
  EventFocusIn
  EventFocusOut
  EventUnknown(UInt)
} derive(Eq)

///|
pub extend TerminalEventKind with Eq::{equal, not_equal}

///|
pub(all) enum KeyAction {
  KeyPress
  KeyRepeat
  KeyRelease
  KeyActionUnknown(UInt)
} derive(Eq)

///|
pub extend KeyAction with Eq::{equal, not_equal}

///|
pub(all) enum KeyCode {
  KeyChar(UInt)
  KeyEnter
  KeyEscape
  KeyBackspace
  KeyTab
  KeyBackTab
  KeyLeft
  KeyRight
  KeyUp
  KeyDown
  KeyHome
  KeyEnd
  KeyPageUp
  KeyPageDown
  KeyDelete
  KeyInsert
  KeyFunction(UInt)
  KeyUnknown(UInt)
} derive(Eq)

///|
pub extend KeyCode with Eq::{equal, not_equal}

///|
pub(all) struct TerminalEvent {
  abi_version : UInt
  struct_size : UInt
  kind : UInt
  key_code : UInt
  codepoint : UInt
  modifiers : UInt
  key_action : UInt
  width : UInt
  height : UInt
  mouse_x : UInt
  mouse_y : UInt
  mouse_kind : UInt
  mouse_button : UInt
  text_len : UInt
}

///|
pub fn modifier_shift() -> UInt {
  1U << 0
}

///|
pub fn modifier_control() -> UInt {
  1U << 1
}

///|
pub fn modifier_alt() -> UInt {
  1U << 2
}

///|
pub fn modifier_super() -> UInt {
  1U << 3
}

///|
pub fn modifier_hyper() -> UInt {
  1U << 4
}

///|
pub fn modifier_meta() -> UInt {
  1U << 5
}

///|
pub fn TerminalEvent::has_modifier(
  self : TerminalEvent,
  modifier : UInt,
) -> Bool {
  (self.modifiers & modifier) != 0U
}

///|
pub fn TerminalEvent::kind_value(
  self : TerminalEvent,
) -> TerminalEventKind {
  match self.kind {
    0U => EventNone
    1U => EventKey
    2U => EventResize
    3U => EventMouse
    4U => EventPaste
    5U => EventFocusIn
    6U => EventFocusOut
    other => EventUnknown(other)
  }
}

///|
pub fn TerminalEvent::key_action_value(
  self : TerminalEvent,
) -> KeyAction {
  match self.key_action {
    1U => KeyPress
    2U => KeyRepeat
    3U => KeyRelease
    other => KeyActionUnknown(other)
  }
}

///|
pub fn TerminalEvent::key_code_value(
  self : TerminalEvent,
) -> KeyCode {
  match self.key_code {
    1U => KeyChar(self.codepoint)
    2U => KeyEnter
    3U => KeyEscape
    4U => KeyBackspace
    5U => KeyTab
    6U => KeyBackTab
    7U => KeyLeft
    8U => KeyRight
    9U => KeyUp
    10U => KeyDown
    11U => KeyHome
    12U => KeyEnd
    13U => KeyPageUp
    14U => KeyPageDown
    15U => KeyDelete
    16U => KeyInsert
    code =>
      if code >= 100U && code <= 355U {
        KeyFunction(code - 100U)
      } else {
        KeyUnknown(code)
      }
  }
}

///|
pub fn decode_terminal_event(
  words : FixedArray[UInt],
) -> TerminalEvent? {
  if words.length() < 14 {
    return None
  }
  Some({
    abi_version: words[0],
    struct_size: words[1],
    kind: words[2],
    key_code: words[3],
    codepoint: words[4],
    modifiers: words[5],
    key_action: words[6],
    width: words[7],
    height: words[8],
    mouse_x: words[9],
    mouse_y: words[10],
    mouse_kind: words[11],
    mouse_button: words[12],
    text_len: words[13],
  })
}

///|
pub fn event_validation_marker() -> Int {
  let words : FixedArray[UInt] = [
    2U, 56U, 1U, 1U, 113U, 2U, 1U,
    0U, 0U, 0U, 0U, 0U, 0U, 0U,
  ]
  match decode_terminal_event(words) {
    Some(event) =>
      if event.kind_value() == EventKey &&
        event.key_code_value() == KeyChar(113U) &&
        event.key_action_value() == KeyPress &&
        event.has_modifier(modifier_control()) {
        1
      } else {
        0
      }
    None => 0
  }
}
