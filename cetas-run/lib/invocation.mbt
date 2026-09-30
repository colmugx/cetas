///|
/// Top-level actions. RunCli and parse_run_cli remain the run-only API.
pub(all) enum InvocationAction {
  Run(RunCli)
  Help
  Version
  /// Empty provider means the login frontend chooses a provider.
  Login(String)
}

///|
/// Parse argv without IO. Queries are recognized only at flag positions:
/// values of run flags and everything following `--` are literal data.
/// The first query wins, even when other arguments would fail run parsing.
pub fn parse_invocation(
  argv : Array[String],
) -> Result[InvocationAction, String] {
  let mut i = 0
  let mut login = false
  while i < argv.length() {
    match argv[i] {
      "--" => break
      "--help" | "-h" => return Ok(Help)
      "--version" => return Ok(Version)
      "--model" | "--effort" | "--session" | "--permission" => {
        if argv.get(i + 1) is Some("--") {
          break
        }
        i += 2
      }
      "--login" => {
        login = true
        i += 1
        if i < argv.length() && !argv[i].has_prefix("-") {
          i += 1
        }
      }
      _ => i += 1
    }
  }
  // Login is standalone: do not accidentally run a task or accept run flags.
  if login {
    match argv {
      ["--login"] => return Ok(Login(""))
      ["--login", provider] if provider != "" && !provider.has_prefix("-") =>
        return Ok(Login(provider))
      _ =>
        return Err(
          "--login [provider] must be used alone; run flags and tasks are not accepted",
        )
    }
  }
  match parse_run_cli(argv) {
    Ok(cli) => Ok(Run(cli))
    Err(message) => Err(message)
  }
}
