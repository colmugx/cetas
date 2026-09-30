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
