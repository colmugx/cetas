///|
/// cli_wbtest.mbt — the decided flag surface, pinned.

///|
test "cli parses the full flag surface and captures the -- task" {
  let parsed = parse_headless_cli([
    "--model", "opencode/gpt-5.1-codex", "--effort", "high", "--session", "cetas-42",
    "--permission", "readonly", "--jsonl", "--", "fix", "the", "bug",
  ])
  let cli = match parsed {
    Ok(cli) => cli
    Err(message) => fail("full flag surface must parse: \{message}")
  }
  assert_eq(cli.model, "opencode/gpt-5.1-codex")
  assert_eq(cli.effort, "high")
  assert_eq(cli.session_id, "cetas-42")
  assert_false(cli.yolo)
  assert_true(cli.permission_mode is Some(_))
  assert_true(cli.jsonl)
  assert_eq(cli.task, "fix the bug")
}

///|
test "cli defaults: no flags means the interactive default posture" {
  let cli = match parse_headless_cli([]) {
    Ok(cli) => cli
    Err(message) => fail("empty argv must parse: \{message}")
  }
  assert_eq(cli.model, "")
  assert_eq(cli.effort, "")
  assert_eq(cli.session_id, "")
  assert_false(cli.yolo)
  assert_false(cli.jsonl)
  assert_false(cli.verbose)
  assert_false(cli.stream)
  assert_false(cli.show_thinking)
  assert_true(cli.permission_mode is None)
  assert_eq(cli.task, "")
  assert_true(resolve_permission_mode(cli) is @permission.WorkspaceWrite)
  assert_true(wants_terminal_ui(cli))
}

///|
test "cli --yolo selects Yolo mode and drops the terminal ui" {
  let cli = match parse_headless_cli(["--yolo", "--", "ship it"]) {
    Ok(cli) => cli
    Err(message) => fail("--yolo must parse: \{message}")
  }
  assert_true(cli.yolo)
  assert_true(resolve_permission_mode(cli) is @permission.Yolo)
  assert_false(wants_terminal_ui(cli))
}

///|
test "cli --permission accepts exactly the three documented modes" {
  let ro = parse_headless_cli(["--permission", "readonly"])
  assert_true(
    match ro {
      Ok(cli) =>
        match cli.permission_mode {
          Some(@permission.ReadOnly) => true
          _ => false
        }
      Err(_) => false
    },
  )
  let ww = parse_headless_cli(["--permission", "workspace_write"])
  assert_true(
    match ww {
      Ok(cli) =>
        match cli.permission_mode {
          Some(@permission.WorkspaceWrite) => true
          _ => false
        }
      Err(_) => false
    },
  )
  let ia = parse_headless_cli(["--permission", "interactive"])
  assert_true(
    match ia {
      Ok(cli) =>
        match cli.permission_mode {
          Some(@permission.Interactive) => true
          _ => false
        }
      Err(_) => false
    },
  )
  assert_true(parse_headless_cli(["--permission", "yolo"]) is Err(_))
  assert_true(parse_headless_cli(["--permission", "bogus"]) is Err(_))
}

///|
test "cli rejects --yolo together with --permission" {
  let parsed = parse_headless_cli(["--yolo", "--permission", "readonly"])
  match parsed {
    Err(message) => assert_true(message.contains("mutually exclusive"))
    Ok(_) => fail("--yolo with --permission must be rejected")
  }
}

///|
test "cli --jsonl switches stdout to the event stream face" {
  let cli = match parse_headless_cli(["--jsonl", "--", "task"]) {
    Ok(cli) => cli
    Err(message) => fail("--jsonl must parse: \{message}")
  }
  assert_true(cli.jsonl)
  assert_false(cli.yolo)
  // Composable with the unattended posture (the swarm spawn shape).
  let solo = parse_headless_cli(["--jsonl", "--yolo", "--", "task"])
  assert_true(
    match solo {
      Ok(cli) => cli.jsonl && cli.yolo
      Err(_) => false
    },
  )
}

///|
test "cli --verbose, --stream, --show-thinking: independent flags, all default off" {
  let cli = match parse_headless_cli(["--verbose", "--", "task"]) {
    Ok(cli) => cli
    Err(message) => fail("--verbose must parse: \{message}")
  }
  assert_true(cli.verbose)
  assert_false(cli.stream)
  assert_false(cli.show_thinking)
  let streamed = match parse_headless_cli(["--stream", "--", "task"]) {
    Ok(cli) => cli
    Err(message) => fail("--stream must parse: \{message}")
  }
  // --stream is independent of --verbose: the delta face and the event log
  // may coexist, neither implies the other.
  assert_true(streamed.stream)
  assert_false(streamed.verbose)
  let thinking = match parse_headless_cli(["--show-thinking", "--", "task"]) {
    Ok(cli) => cli
    Err(message) => fail("--show-thinking must parse: \{message}")
  }
  assert_true(thinking.show_thinking)
  assert_false(thinking.stream)
  assert_false(thinking.verbose)
  // All three compose with each other and with --jsonl (--jsonl wins stdout;
  // the flag record stays truthful).
  let combined = parse_headless_cli([
    "--jsonl", "--stream", "--verbose", "--show-thinking", "--", "task",
  ])
  assert_true(
    match combined {
      Ok(cli) => cli.jsonl && cli.verbose && cli.stream && cli.show_thinking
      Err(_) => false
    },
  )
}

///|
test "cli rejects unknown flags, stray arguments, and missing values" {
  assert_true(parse_headless_cli(["--json"]) is Err(_))
  assert_true(parse_headless_cli(["--jsonl=1"]) is Err(_))
  assert_true(parse_headless_cli(["stray"]) is Err(_))
  assert_true(parse_headless_cli(["--model"]) is Err(_))
  assert_true(parse_headless_cli(["--effort"]) is Err(_))
  assert_true(parse_headless_cli(["--session"]) is Err(_))
  assert_true(parse_headless_cli(["--permission"]) is Err(_))
}
