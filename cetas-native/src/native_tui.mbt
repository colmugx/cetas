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
extern "C" fn exit(code : Int) = "exit"

///|
fn main {
  let scene = @ui.Scene::validation()
  let batch_ok = ctui_headless_batch_probe(
    scene.words,
    scene.words.length().reinterpret_as_uint(),
    scene.text,
    scene.text.length().reinterpret_as_uint(),
  ) == 1

  let ok = ctui_abi_version() == 2 &&
    ctui_headless_probe() == 1 &&
    batch_ok &&
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
