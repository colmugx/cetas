///|
/// Native terminal implementation is absent on the wasm target. Keep its
/// imported dependencies explicitly referenced without exposing terminal
/// authentication in a sandbox with no controlling terminal.
#cfg(target="wasm")
#coverage.skip
let _keep_native_bootstrap_imports : Unit = {
  ignore(@async.platform)
  let _ : @aqueue.Queue[Unit]? = None
  ignore(@fs.exists)
  let _ : (@types.Fd) -> Unit = ignore
  ignore(@utf8.encode)
}
