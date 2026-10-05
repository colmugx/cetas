///|
fn is_windows() -> Bool {
  @env.get_env_var("OS") == Some("Windows_NT")
}

///|
fn python_command() -> String {
  if is_windows() { "python" } else { "python3" }
}

///|
fn recipe_platform() -> String {
  if is_windows() { "windows" } else { "unix" }
}

///|
fn npm_command() -> String {
  if is_windows() { "cmd" } else { "npm" }
}

///|
fn npm_args(args : Array[String]) -> Array[String] {
  if !is_windows() {
    return args
  }
  let command : Array[String] = ["/d", "/s", "/c", "npm"]
  command.append(args)
  command
}

///|
async fn run_checked(
  command : String,
  args : Array[String],
  cwd? : StringView,
  stdout~ : &@process.ProcessOutput,
  stderr~ : &@process.ProcessOutput,
) -> Unit {
  let code = @process.run(
    command,
    args,
    cwd~,
    stdout~,
    stderr~,
  )
  if code != 0 {
    abort(
      "cetas-web dev: child command failed with exit code " +
      code.to_string() +
      ": " +
      command,
    )
  }
}

///|
async fn main {
  let stdout : &@process.ProcessOutput = @stdio.stdout
  let stderr : &@process.ProcessOutput = @stdio.stderr

  println("cetas-web dev: preparing public/web recipe")
  run_checked(
    python_command(),
    [
      "scripts/prepare-recipe.py",
      "--flavor",
      "public",
      "--frontend",
      "web",
      "--platform",
      recipe_platform(),
    ],
    stdout~,
    stderr~,
  )

  println("cetas-web dev: preparing frontend dependencies")
  run_checked(
    npm_command(),
    npm_args(["install", "--no-audit", "--no-fund", "--prefer-offline"]),
    cwd="cetas-web/web",
    stdout~,
    stderr~,
  )

  println("")
  println("cetas-web dev:")
  println("  app       http://127.0.0.1:5173")
  println("  moonback  http://127.0.0.1:8787")
  println("  ctrl-c    stops both processes")
  println("")

  @async.with_task_group(group => {
    let server = @process.spawn(
      group,
      "moon",
      ["run", "./cetas-web/server"],
      stdout~,
      stderr~,
      no_wait=true,
    )
    let frontend = @process.spawn(
      group,
      npm_command(),
      npm_args(["run", "dev", "--", "--host", "127.0.0.1"]),
      cwd="cetas-web/web",
      stdout~,
      stderr~,
      no_wait=true,
    )

    let exit_code = @async.any([
      () => server.wait(),
      () => frontend.wait(),
    ])
    if exit_code != 0 {
      abort(
        "cetas-web dev: child process exited with " + exit_code.to_string(),
      )
    }
  })
}
