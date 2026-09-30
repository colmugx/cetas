///|
#warnings("-unused_async")
async test "startup queries do not create config or emit onboarding" {
  for argv in [["--help"], ["-h"], ["--version"], ["--bad", "--help"]] {
    let action = prepare_invocation(
      argv,
      home="unused",
      native=true,
      create_settings=async fn(_, _) { fail("query must not touch filesystem") },
      note=async fn(_) noraise { abort("query must not emit onboarding") },
    )
    assert_true(action is Ok(Help) || action is Ok(Version))
  }
}

///|
#warnings("-unused_async")
async test "startup creates before argument rejection with shared core paths" {
  let events : Array[String] = []
  let action = prepare_invocation(
    ["hello"],
    home="/custom/home",
    native=true,
    create_settings=async fn(dir, path) {
      assert_eq(dir, @cetas_core.cetas_dir("/custom/home"))
      assert_eq(path, @cetas_core.settings_path("/custom/home"))
      events.push("create")
      true
    },
    note=async fn(text) noraise {
      events.push("stderr")
      assert_true(text.contains("--login")) catch {
        _ => abort("missing guide")
      }
    },
  )
  assert_true(action is Err(_))
  events.push("report error")
  assert_eq(events, ["create", "stderr", "report error"])
}

///|
#warnings("-unused_async")
async test "startup before stdin; existing no-args prompt and new guide use the note sink" {
  for created in [false, true] {
    let events : Array[String] = []
    let stderr = StringBuilder()
    let action = prepare_invocation(
      [],
      home="custom",
      native=false,
      create_settings=async fn(_, _) {
        events.push("create")
        created
      },
      note=async fn(text) noraise {
        events.push("stderr")
        stderr.write_string(text)
      },
    )
    let cli = match action {
      Ok(Run(cli)) => cli
      _ => fail("expected run")
    }
    let task = resolve_task(
      if cli.task == "" {
        None
      } else {
        Some(cli.task)
      },
      read_line=async fn() noraise {
        events.push("stdin")
        Some(" one task\n")
      },
    )
    assert_eq(task, Some("one task"))
    assert_eq(events, ["create", "stderr", "stdin"])
    assert_true(stderr.to_string().contains("cetas-run --help"))
    assert_true(stderr.to_string().contains("press Enter"))
    if created {
      assert_true(stderr.to_string().contains("credentials are shared"))
      assert_true(stderr.to_string().contains("if already logged in"))
      assert_true(stderr.to_string().contains("/login"))
      assert_true(stderr.to_string().contains("sandbox access"))
    } else {
      assert_true(stderr.to_string().contains("enter one task line"))
      assert_false(stderr.to_string().contains("created"))
    }
  }
}

///|
#warnings("-unused_async")
async test "startup existing flagged runs are quiet and argv task never reads stdin" {
  for
    flags in [
      ["--", "task"],
      ["--jsonl", "--", "task"],
      ["--stream", "--verbose", "--", "task"],
    ] {
    let action = prepare_invocation(
      flags,
      home="custom",
      native=true,
      create_settings=async fn(_, _) { false },
      note=async fn(_) noraise { abort("existing flagged run must be quiet") },
    )
    let cli = match action {
      Ok(Run(cli)) => cli
      _ => fail("expected run")
    }
    let task = resolve_task(Some(cli.task), read_line=async fn() noraise {
      abort("argv task must not read stdin")
    })
    assert_eq(task, Some("task"))
  }
}

///|
#warnings("-unused_async")
async test "startup filesystem failure precedes argument error and any notes or stdin" {
  try
    prepare_invocation(
      ["hello"],
      home="custom",
      native=true,
      create_settings=async fn(_, _) { raise Failure("creator failed") },
      note=async fn(_) noraise {
        abort("failed bootstrap must not emit success guide")
      },
    )
  catch {
    Failure(message) => assert_eq(message, "creator failed")
    err => fail("unexpected error: \{err}")
  } noraise {
    _ => fail("filesystem error must propagate")
  }
}

///|
async test "bootstrap creates complete settings once and preserves existing bytes and metadata" {
  let home = @fs.tmpdir(prefix="cetas-run-bootstrap")
  defer @fs.rmdir(home, recursive=true)
  let dir = @cetas_core.cetas_dir(home)
  let path = @cetas_core.settings_path(home)
  assert_true(create_minimal_settings(dir, path))
  assert_eq(@fs.read_file(path).text(), "{\"providers\":{}}\n")
  let modified = @fs.mtime(path)
  assert_false(create_minimal_settings(dir, path))
  assert_eq(@fs.mtime(path), modified)
  @fs.write_file(path, "malformed user config\n")
  let modified = @fs.mtime(path)
  assert_false(create_minimal_settings(dir, path))
  assert_eq(@fs.read_file(path).text(), "malformed user config\n")
  assert_eq(@fs.mtime(path), modified)
  assert_eq(@fs.readdir(dir, include_hidden=true), ["settings.json"])
}

///|
async test "bootstrap concurrent starters publish once with no partial file or leftovers" {
  let home = @fs.tmpdir(prefix="cetas-run-race")
  defer @fs.rmdir(home, recursive=true)
  let dir = @cetas_core.cetas_dir(home)
  let path = @cetas_core.settings_path(home)
  let results : Array[Bool] = []
  @async.with_task_group(group => {
    for _ in 0..<12 {
      group.spawn_bg(() => results.push(create_minimal_settings(dir, path)))
    }
  })
  assert_eq(results.filter(x => x).length(), 1)
  assert_eq(@fs.read_file(path).text(), "{\"providers\":{}}\n")
  assert_eq(@fs.readdir(dir, include_hidden=true), ["settings.json"])
}

///|
async test "bootstrap existing directory entries are untouched; real FS errors propagate" {
  let home = @fs.tmpdir(prefix="cetas-run-errors")
  defer @fs.rmdir(home, recursive=true)
  let dir = @cetas_core.cetas_dir(home)
  let path = @cetas_core.settings_path(home)
  @fs.mkdir(dir)
  @fs.mkdir(path)
  assert_false(create_minimal_settings(dir, path))
  assert_true(@fs.kind(path) is @fs.Directory)
  @fs.rmdir(path)
  @fs.rmdir(dir)
  @fs.write_file(dir, "not a directory")
  try create_minimal_settings(dir, path) catch {
    _ => ()
  } noraise {
    _ => fail("ENOTDIR must not be treated as missing settings")
  }
  assert_eq(@fs.read_file(dir).text(), "not a directory")
}
