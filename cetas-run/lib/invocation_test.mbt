///|
test "invocation queries at flag positions only" {
  assert_true(@lib.parse_invocation(["--help"]) is Ok(@lib.Help))
  assert_true(@lib.parse_invocation(["-h"]) is Ok(@lib.Help))
  assert_true(@lib.parse_invocation(["--version"]) is Ok(@lib.Version))
  assert_true(@lib.parse_invocation(["--bad", "--help"]) is Ok(@lib.Help))
  assert_true(
    @lib.parse_invocation(["--jsonl", "--version"]) is Ok(@lib.Version),
  )
  assert_true(
    @lib.parse_invocation(["--version", "--help"]) is Ok(@lib.Version),
  )
  for flag in ["--model", "--effort", "--session"] {
    for literal in ["--help", "-h", "--version", "--login"] {
      assert_true(@lib.parse_invocation([flag, literal]) is Ok(@lib.Run(_)))
      assert_true(
        @lib.parse_invocation([flag, literal, "--help"]) is Ok(@lib.Help),
      )
    }
  }
  for literal in ["--help", "-h", "--version", "--login"] {
    assert_true(@lib.parse_invocation(["--permission", literal]) is Err(_))
    let cli = match @lib.parse_invocation(["--", literal]) {
      Ok(@lib.Run(cli)) => cli
      _ => fail("task text must stay literal")
    }
    assert_eq(cli.task, literal)
    assert_true(@lib.parse_invocation(["--model", "--", literal]) is Err(_))
  }
  assert_true(
    @lib.parse_invocation(["--session", "s", "--", "--version", "--login"])
    is Ok(@lib.Run(_)),
  )
}

///|
test "invocation standalone login and positional task rejection" {
  assert_true(@lib.parse_invocation(["--login"]) is Ok(@lib.Login("")))
  assert_true(
    @lib.parse_invocation(["--login", "openai"]) is Ok(@lib.Login("openai")),
  )
  assert_true(@lib.parse_invocation(["--login", "--help"]) is Ok(@lib.Help))
  for
    argv in [
      ["--login", ""],
      ["--login", "openai", "extra"],
      ["--login", "--yolo"],
      ["--yolo", "--login"],
      ["--model", "x", "--login"],
      ["--login", "--", "task"],
      ["--login", "--login"],
    ] {
    assert_true(@lib.parse_invocation(argv) is Err(_))
  }
  match @lib.parse_invocation(["hello"]) {
    Err(message) => assert_true(message.contains("use --"))
    _ => fail("positional task is not supported")
  }
  assert_true(@lib.parse_invocation([]) is Ok(@lib.Run(_)))
}

///|
test "static help describes all faces and setup targets" {
  let help = @lib.invocation_help()
  for
    text in [
      "--login", "-h", "--version", "--model", "--effort", "--session", "--permission",
      "auto", "--jsonl", "--stream", "--verbose", "--show-thinking", "stdin", "stderr",
      "CETAS_HOME", "sandbox", "providers",
    ] {
    assert_true(help.contains(text))
  }
  let native = @lib.onboarding_guide("/custom/settings.json", native=true)
  assert_true(native.contains("/custom/settings.json"))
  assert_true(native.contains("Otherwise run cetas-run --login."))
  assert_false(native.contains("[provider]"))
  for
    guide in [
      native,
      @lib.onboarding_guide("/custom/settings.json", native=false),
    ] {
    assert_true(guide.contains("credentials are shared"))
    assert_true(guide.contains("if already logged in"))
    assert_true(guide.contains("cetas-run -- \"hello\""))
    assert_true(guide.contains("one task line on stdin and press Enter"))
    assert_true(guide.contains("cetas-run --help"))
  }
  let wasm = @lib.onboarding_guide("/custom/settings.json", native=false)
  assert_true(wasm.contains("/login"))
  assert_true(wasm.contains("same CETAS_HOME"))
  assert_true(wasm.contains("sandbox access"))
  assert_true(wasm.contains("manually"))
}
