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
    skills: builtin_manual_skills(),
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
  assert_true(
    manifest.prompt_contributors[0].system_prompt().contains("activate_skill"),
  )
}
