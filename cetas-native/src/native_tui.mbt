/// Native TUI validation host.
///
/// Raw C ABI declarations live in @native. This executable verifies the
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

  let terminal = match @ui.Terminal::open_inline(3U) {
    Some(value) => value
    None => {
      println("cetas-tui validation: FAILED")
      exit(1)
      return
    }
  }

  let batch_tty_ok = terminal.render(scene) == 0

  let (viewport_status, viewport_words) = terminal.viewport_size()
  let viewport_ok = viewport_status == 0 &&
    viewport_words[0] == 80U &&
    viewport_words[1] == 3U

  let (poll_status, event_words) = terminal.poll_raw(0UL)
  let event_decode_ok = match @ui.decode_terminal_event(event_words) {
    Some(event) => event.abi_version == 2
    None => false
  }
  let poll_ok = (poll_status == 0 || poll_status == 1) && event_decode_ok

  terminal.close()
  let close_ok = !terminal.is_open()
  terminal.close()

  let ok = @native.abi_version() == 2 &&
    @native.headless_probe() == 1 &&
    batch_decode_ok &&
    batch_tty_ok &&
    viewport_ok &&
    poll_ok &&
    close_ok &&
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
