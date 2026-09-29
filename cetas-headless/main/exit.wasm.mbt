///|
/// MoonRun Wasm process exit. This is the runtime import used by
/// moonbitlang/async's own Wasm integration layer.
#unsafe_skip_stub_check
fn exit(code : Int) = "moonbitlang/async" "runtime/exit"
