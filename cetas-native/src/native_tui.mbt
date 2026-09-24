/// Native TUI validation host.
///
/// Raw C ABI declarations live in @native. This executable verifies that the
/// MoonBit-facing substrate links and behaves correctly under a real PTY.

///|
extern "C" fn exit(code : Int) = "exit"

///|
fn main {
  let scene = @ui.Scene::validation()
  let word_count = scene.words.length().reinterpret_as_uint()
  let text_len = scene.text.length().reinterpret_as_uint()

  let batch_decode_ok = @native.headless_batch_probe(
    scene.words,
    word_count,
    scene.text,
    text_len,
  ) == 1

  let tui = @native.open_inline(3U)
  let batch_tty_ok = @native.render_batch(
    tui,
    scene.words,
    word_count,
    scene.text,
    text_len,
  ) == 0

  let viewport_words : FixedArray[UInt] = FixedArray::make(2, 0U)
  let viewport_ok = @native.viewport_size(tui, viewport_words, 2U) == 0 &&
    viewport_words[0] == 80U &&
    viewport_words[1] == 3U

  let event_words : FixedArray[UInt] = FixedArray::make(14, 0U)
  let poll_status = @native.poll_words(tui, 0UL, event_words, 14U)
  let event_decode_ok = match @ui.decode_terminal_event(event_words) {
    Some(event) => event.abi_version == 2
    None => false
  }
  let poll_ok = (poll_status == 0 || poll_status == 1) && event_decode_ok

  @native.close(tui)

  let ok = @native.abi_version() == 2 &&
    @native.headless_probe() == 1 &&
    batch_decode_ok &&
    batch_tty_ok &&
    viewport_ok &&
    poll_ok &&
    @native.inline_probe(8) == 1 &&
    @native.event_size() > 0 &&
    @native.tty_probe() == 1 &&
    @app.validation_marker() == 1 &&
    @ui.validation_marker() == 1

  if ok {
    println("cetas-tui validation: ok")
  } else {
    println("cetas-tui validation: FAILED")
    exit(1)
  }
}
