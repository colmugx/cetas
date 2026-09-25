/// Raw native terminal handle. Ownership is explicit: values returned by
/// `open_inline` must be released exactly once with `close`.

///|
#external
pub type RawTui

///|
pub extern "C" fn abi_version() -> UInt = "ctui_abi_version"

///|
pub extern "C" fn headless_probe() -> UInt = "ctui_headless_probe"

///|
#borrow(words, text)
pub extern "C" fn headless_batch_probe(
  words : FixedArray[UInt],
  word_count : UInt,
  text : Bytes,
  text_len : UInt,
) -> UInt = "ctui_headless_batch_probe"

///|
#borrow(command_words, style_words, text)
pub extern "C" fn headless_scene_probe(
  command_words : FixedArray[UInt],
  command_word_count : UInt,
  style_words : FixedArray[UInt],
  style_word_count : UInt,
  text : Bytes,
  text_len : UInt,
) -> UInt = "ctui_headless_scene_probe"

///|
pub extern "C" fn inline_probe(rows : UInt) -> UInt = "ctui_inline_probe"

///|
pub extern "C" fn event_size() -> UInt = "ctui_event_size"

///|
pub extern "C" fn tty_probe() -> UInt = "ctui_tty_probe"

///|
pub extern "C" fn open_inline(rows : UInt) -> RawTui = "ctui_open_inline"

///|
pub extern "C" fn is_null(tui : RawTui) -> UInt = "ctui_is_null"

///|
pub extern "C" fn close(tui : RawTui) = "ctui_close"

///|
pub extern "C" fn suspend(tui : RawTui) -> Int = "ctui_suspend"

///|
pub extern "C" fn resume_terminal(tui : RawTui) -> Int = "ctui_resume"

///|
#borrow(words, text)
pub extern "C" fn render_batch(
  tui : RawTui,
  words : FixedArray[UInt],
  word_count : UInt,
  text : Bytes,
  text_len : UInt,
) -> Int = "ctui_render_batch"

///|
#borrow(command_words, style_words, text)
pub extern "C" fn render_scene(
  tui : RawTui,
  command_words : FixedArray[UInt],
  command_word_count : UInt,
  style_words : FixedArray[UInt],
  style_word_count : UInt,
  text : Bytes,
  text_len : UInt,
) -> Int = "ctui_render_scene"

///|
#borrow(text)
pub extern "C" fn insert_before_text(
  tui : RawTui,
  text : Bytes,
  text_len : UInt,
) -> Int = "ctui_insert_before_text"

///|
#borrow(out_words)
pub extern "C" fn viewport_size(
  tui : RawTui,
  out_words : FixedArray[UInt],
  capacity : UInt,
) -> Int = "ctui_viewport_size"

///|
#borrow(out_words)
pub extern "C" fn poll_words(
  tui : RawTui,
  timeout_ms : UInt64,
  out_words : FixedArray[UInt],
  capacity : UInt,
) -> Int = "ctui_poll_words"

///|
pub extern "C" fn event_text_len(tui : RawTui) -> UInt = "ctui_event_text_len"

///|
#borrow(out)
pub extern "C" fn event_text_copy(
  tui : RawTui,
  out : FixedArray[Byte],
  capacity : UInt,
) -> Int = "ctui_event_text_copy"
