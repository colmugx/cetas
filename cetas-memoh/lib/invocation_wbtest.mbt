///|
test "Memoh pre-ACP commands are parsed without touching runtime state" {
  assert_true(parse_memoh_invocation([]) is MemohServe)
  assert_true(parse_memoh_invocation(["serve"]) is MemohServe)
  assert_true(parse_memoh_invocation(["--version"]) is MemohVersion)
  assert_true(parse_memoh_invocation(["--help"]) is MemohHelp)
  assert_true(parse_memoh_invocation(["setup"]) is MemohSetup(""))
  assert_true(parse_memoh_invocation(["setup", "openai"]) is MemohSetup("openai"))
  assert_true(parse_memoh_invocation(["login"]) is MemohLogin(""))
  assert_true(parse_memoh_invocation(["login", "kimi"]) is MemohLogin("kimi"))
  for args in [
    ["login", "openai", "extra"],
    ["setup", "--bad"],
    ["--unknown"],
    ["serve", "extra"],
    ["login", "--token", "secret"],
  ] {
    assert_true(parse_memoh_invocation(args) is MemohInvalid(_))
  }
}
