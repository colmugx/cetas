///|
#cfg(target="wasm")
pub async fn run_login(
  home~ : String,
  provider~ : String,
  note~ : async (String) -> Unit noraise,
) -> Unit {
  ignore(home)
  ignore(provider)
  note(
    "cetas-run --login is unsupported on the wasm target. Use native cetas-run --login or Cetas /login with the same shared home (~/.cetas). For a wasm sandbox, authenticate outside the sandbox and explicitly grant access to that shared home; do not place credentials in the project.\n",
  )
  raise @posoco.CommandError::ExecutionFailed(
    "Login is unsupported on the wasm target",
  )
}

///|
// Native-only login and terminal-auth code leaves these imports unused on wasm.
#coverage.skip
let _keep_native_only_imports : Unit = {
  ignore(@credentials.encode_provider_credential)
  ignore(@env.rand)
  let _ : (@types.Fd) -> Unit = ignore
  let _ : (&@oauth.AuthInteraction) -> Unit = ignore
}
