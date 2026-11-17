///|
#cfg(target="wasm")
test "bootstrap test-only native imports stay declared for wasm checks" {
  ignore(@stdio.stderr)
  ignore(@env.args)
}
