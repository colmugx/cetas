///|
async test "help: invoke returns the quick reference and manual pointers" {
  let forme = Forme::Forme()
  let port : &@posoco.CommandPort = forme
  let outcome = port.invoke("help", Json::null())
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, ..) => {
      assert_true(feedback.contains("cetas is a coding agent"))
      assert_true(feedback.contains("cetas-about"))
      assert_true(feedback.contains("cetas-usage"))
      assert_true(feedback.contains("cetas-config"))
      assert_true(feedback.contains("Type / to browse"))
    }
    _ => fail("/help must succeed")
  }
}

///|
async test "help: host note is appended when provided, absent otherwise" {
  let with_note = Forme::Forme(host_note=Some("ESC — interrupt the turn"))
  let port : &@posoco.CommandPort = with_note
  match port.invoke("help", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      assert_true(feedback.contains("ESC — interrupt the turn"))
    _ => fail("/help with host note must succeed")
  }
  let without = Forme::Forme()
  let port2 : &@posoco.CommandPort = without
  match port2.invoke("help", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      assert_false(feedback.contains("ESC"))
    _ => fail("/help without host note must succeed")
  }
}

///|
async test "help: version note leads the first line when provided" {
  let with_version = Forme::Forme(version_note=Some("0.10.9 (npm)"))
  let port : &@posoco.CommandPort = with_version
  match port.invoke("help", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, ..) => {
      assert_true(feedback.contains("cetas 0.10.9 (npm)"))
      assert_false(feedback.contains("cetas is a coding agent"))
    }
    _ => fail("/help with version note must succeed")
  }
}

///|
async test "help: unknown id fails closed" {
  let forme = Forme::Forme()
  let port : &@posoco.CommandPort = forme
  match port.invoke("other", Json::null()) {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("unknown command"))
    _ => fail("unknown command id must fail")
  }
}

///|
test "manuals: builtins form a valid catalog and render into the prompt" {
  let catalog = @skills.SkillCatalog::{
    skills: Forme::Forme().builtin_manual_skills(),
    diagnostics: [],
  }
  assert_eq(catalog.validate(), Ok(()))
  let rendered = catalog.render_prompt_body(max_chars=8000)
  for name in ["cetas-about", "cetas-usage", "cetas-config"] {
    assert_true(rendered.contains(name))
  }
}

///|
test "forme: manifest contributes one help command and one prompt section" {
  let forme = Forme::Forme()
  let ext : &@posoco.Extension = forme
  let manifest = ext.manifest()
  assert_eq(manifest.commands.length(), 1)
  let defs = manifest.commands[0].commands()
  assert_eq(defs.length(), 1)
  assert_eq(defs[0].id, "help")
  assert_eq(manifest.prompt_contributors.length(), 1)
  let routing = manifest.prompt_contributors[0].system_prompt()
  assert_true(routing.contains("activate_skill"))
  assert_true(routing.contains("cetas-config"))
  assert_true(routing.length() < 190)
}

///|
test "manuals: config is the flagship and documents settings.json" {
  let config = cetas_config_manual()
  assert_true(config.contains("primary job"))
  assert_true(
    config.contains("~/.cetas/settings.json") ||
    config.contains("settings.json"),
  )
  for key in ["providers", "model", "reasoning_effort", "decision_model"] {
    assert_true(config.contains("\"\{key}\""))
  }
  assert_true(config.contains("CETAS_HOME"))
  assert_true(config.contains("preserving every unrelated key"))
  assert_true(config.contains("credentials"))
  assert_true(config.contains("context_window"))
}

///|
test "manuals: usage covers the current command surface and cetas-js keys" {
  let usage = cetas_usage_manual()
  for
    cmd in [
      "/new", "/sessions", "/resume", "/rewind", "/compact", "/model", "/login",
      "/skills", "/permission", "/questions", "/goal", "/workflow", "/board", "/status",
      "/quota",
    ] {
    assert_true(usage.contains(cmd))
  }
  assert_true(usage.contains("bash_status"))
  assert_true(usage.contains("double-ESC"))
  assert_true(usage.contains("ctrl+t"))
}

///|
test "manuals: about lists only product hosts and never PoCs" {
  let about = Forme::Forme().builtin_manual_skills()
  let body = about[2].body.unwrap()
  for host in ["cetas-js", "cetas-acp", "cetas-run"] {
    assert_true(body.contains(host))
  }
  for poc in ["cetas-native", "cetas-web", "cetas-console", "cetas-headless"] {
    assert_false(body.contains(poc))
  }
  assert_true(body.contains("@posoco/cetas"))
  assert_true(body.contains("proof-of-concept"))
}

///|
test "manuals: about interpolates the running version when configured" {
  let with_version = Forme::Forme(version_note=Some("0.10.9 (npm)")).builtin_manual_skills()
  let about = with_version[2].body.unwrap()
  assert_true(about.contains("Running version: 0.10.9 (npm)"))
  assert_false(about.contains("cannot determine it"))
  let without = Forme::Forme().builtin_manual_skills()
  let plain = without[2].body.unwrap()
  assert_true(plain.contains("cannot determine it"))
  assert_false(plain.contains("Running version:"))
}

///|
test "manuals: self-introduction policy is progressive disclosure" {
  let about = cetas_about_manual()
  assert_true(about.contains("真拿你没办法，坐好喽"))
  assert_true(about.contains("at most two"))
  assert_true(about.contains("manifest/README-level reads"))
  assert_true(about.contains("never source files"))
}
