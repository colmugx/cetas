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
/// Global shortcut listeners must ignore Kitty key-release events. Press and
/// repeat remain actionable, matching cetas-js after its isKeyRelease guard.
pub fn TerminalEvent::is_actionable_key(self : TerminalEvent) -> Bool {
  if self.kind_value() != EventKey {
    return false
  }
  match self.key_action_value() {
    KeyPress | KeyRepeat => true
    KeyRelease | KeyActionUnknown(_) => false
  }
}

///|
pub fn TerminalEvent::is_key_release(self : TerminalEvent) -> Bool {
  self.kind_value() == EventKey && self.key_action_value() == KeyRelease
}

///|
/// Match one normalized key chord after Crossterm has decoded terminal escape
/// sequences. Modifier matching is exact; callers opt into each accepted chord
/// explicitly instead of accidentally firing ctrl/alt variants.
pub fn TerminalEvent::matches_key(
  self : TerminalEvent,
  code : KeyCode,
  modifiers : UInt,
) -> Bool {
  self.is_actionable_key() &&
    self.key_code_value() == code &&
    self.modifiers == modifiers
}

///|
pub fn TerminalEvent::matches_char(
  self : TerminalEvent,
  codepoint : UInt,
  modifiers : UInt,
) -> Bool {
  self.matches_key(KeyChar(codepoint), modifiers)
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
  guard decode_terminal_event(words) is Some(event) else {
    return 0
  }
  if event.kind_value() != EventKey ||
    event.key_code_value() != KeyChar(113U) ||
    event.key_action_value() != KeyPress ||
    !event.has_modifier(modifier_control()) ||
    !event.is_actionable_key() ||
    !event.matches_char(113U, modifier_control()) ||
    event.matches_char(113U, 0U) {
    return 0
  }

  let release_words : FixedArray[UInt] = [
    2U, 56U, 1U, 1U, 113U, 2U, 3U,
    0U, 0U, 0U, 0U, 0U, 0U, 0U,
  ]
  guard decode_terminal_event(release_words) is Some(release) else {
    return 0
  }
  if !release.is_key_release() ||
    release.is_actionable_key() ||
    release.matches_char(113U, modifier_control()) {
    return 0
  }

  let back_tab_words : FixedArray[UInt] = [
    2U, 56U, 1U, 6U, 0U, 1U, 1U,
    0U, 0U, 0U, 0U, 0U, 0U, 0U,
  ]
  guard decode_terminal_event(back_tab_words) is Some(back_tab) else {
    return 0
  }
  if !back_tab.matches_key(KeyBackTab, modifier_shift()) {
    return 0
  }

  1
}
