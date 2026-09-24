/// Raw validation seam. Public UI wrappers come later.

///|
extern "C" fn ctui_abi_version() -> UInt = "ctui_abi_version"

///|
extern "C" fn ctui_headless_probe() -> UInt = "ctui_headless_probe"

///|
#borrow(words, text)
extern "C" fn ctui_headless_batch_probe(
  words : FixedArray[UInt],
  word_count : UInt,
  text : Bytes,
  text_len : UInt,
) -> UInt = "ctui_headless_batch_probe"

///|
extern "C" fn ctui_inline_probe(rows : UInt) -> UInt = "ctui_inline_probe"

///|
extern "C" fn ctui_event_size() -> UInt = "ctui_event_size"

///|
extern "C" fn ctui_tty_probe() -> UInt = "ctui_tty_probe"

///|
#external
type RawTui

///|
extern "C" fn ctui_open_inline(rows : UInt) -> RawTui = "ctui_open_inline"

///|
extern "C" fn ctui_close(tui : RawTui) = "ctui_close"

///|
#borrow(words, text)
extern "C" fn ctui_render_batch(
  tui : RawTui,
  words : FixedArray[UInt],
  word_count : UInt,
  text : Bytes,
  text_len : UInt,
) -> Int = "ctui_render_batch"

///|
#borrow(out_words)
extern "C" fn ctui_poll_words(
  tui : RawTui,
  timeout_ms : UInt64,
  out_words : FixedArray[UInt],
  capacity : UInt,
) -> Int = "ctui_poll_words"

///|
extern "C" fn exit(code : Int) = "exit"

///|
fn main {
  let scene = @ui.Scene::validation()
  let word_count = scene.words.length().reinterpret_as_uint()
  let text_len = scene.text.length().reinterpret_as_uint()

  let batch_decode_ok = ctui_headless_batch_probe(
    scene.words,
    word_count,
    scene.text,
    text_len,
  ) == 1

  let tui = ctui_open_inline(3U)
  let batch_tty_ok = ctui_render_batch(
    tui,
    scene.words,
    word_count,
    scene.text,
    text_len,
  ) == 0

  let event_words : FixedArray[UInt] = FixedArray::make(14, 0U)
  let poll_status = ctui_poll_words(tui, 0UL, event_words, 14U)
  let event_decode_ok = match @ui.decode_terminal_event(event_words) {
    Some(event) => event.abi_version == 2
    None => false
  }
  let poll_ok = (poll_status == 0 || poll_status == 1) && event_decode_ok
  ctui_close(tui)

  let ok = ctui_abi_version() == 2 &&
    ctui_headless_probe() == 1 &&
    batch_decode_ok &&
    batch_tty_ok &&
    poll_ok &&
    ctui_inline_probe(8) == 1 &&
    ctui_event_size() > 0 &&
    ctui_tty_probe() == 1 &&
    @app.validation_marker() == 1 &&
    @ui.validation_marker() == 1

  if ok {
    println("cetas-tui validation: ok")
  } else {
    println("cetas-tui validation: FAILED")
    exit(1)
  }
}
