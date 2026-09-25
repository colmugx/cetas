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

  let scene_decode_ok = @native.headless_scene_probe(
    scene.words,
    word_count,
    scene.styles,
    scene.styles.length().reinterpret_as_uint(),
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
  let suspend_ok = terminal.suspend() == 0
  let resume_ok = terminal.resume_terminal() == 0
  let redraw_after_resume_ok = terminal.render(@ui.Scene::validation()) == 0

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
    scene_decode_ok &&
    batch_tty_ok &&
    suspend_ok &&
    resume_ok &&
    redraw_after_resume_ok &&
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
    println("scene_decode_ok=\{scene_decode_ok}")
    println("batch_tty_ok=\{batch_tty_ok}")
    println("suspend_ok=\{suspend_ok}")
    println("resume_ok=\{resume_ok}")
    println("redraw_after_resume_ok=\{redraw_after_resume_ok}")
    println("viewport_status=\{viewport_status}")
    println("viewport=\{viewport_words[0]}x\{viewport_words[1]}")
    println("poll_status=\{poll_status}")
    println("event_decode_ok=\{event_decode_ok}")
    println("close_ok=\{close_ok}")
    println("ui_validation=\{@ui.validation_marker()}")
    exit(1)
  }
}
