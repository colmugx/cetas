/// Stable MoonBit view of one normalized terminal event.
///
/// The native ABI transports events as 14 UInt words. This type is purely
/// MoonBit-side; its memory layout is never exposed over C FFI.

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
