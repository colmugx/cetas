/// Raw validation seam. Public UI wrappers come later.

///|
extern "C" fn ctui_abi_version() -> UInt = "ctui_abi_version"

///|
extern "C" fn ctui_headless_probe() -> UInt = "ctui_headless_probe"

///|
extern "C" fn ctui_inline_probe(rows : UInt) -> UInt = "ctui_inline_probe"

///|
extern "C" fn ctui_event_size() -> UInt = "ctui_event_size"

///|
extern "C" fn exit(code : Int) = "exit"

///|
fn main {
  let ok = ctui_abi_version() == 1 &&
    ctui_headless_probe() == 1 &&
    ctui_inline_probe(8) == 1 &&
    ctui_event_size() > 0 &&
    @app.validation_marker() == 1 &&
    @ui.validation_marker() == 1

  if ok {
    println("cetas-tui validation: ok")
  } else {
    println("cetas-tui validation: FAILED")
    exit(1)
  }
}
