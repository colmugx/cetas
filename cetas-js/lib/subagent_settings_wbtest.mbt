///|
async test "subagent first use accepts missing settings without creating files" {
  let fs = @workspace.JsWorkspaceFs()
  let home = "./cetas-subagent-settings-js-" + @cetas_core.mint_session_id()
  fs.mkdir(home, recursive=true)
  defer @async.protect_from_cancel(() => fs.remove(home))
  for stage in 0..<2 {
    if stage == 1 {
      fs.mkdir(home + "/.cetas", recursive=true)
    }
    let (config, kinds) = load_cetas_subagent_settings(home~)
    assert_eq(config, @subagent_kit.SubagentConfig::defaults())
    assert_eq(kinds.length(), 0)
    assert_false(fs.exists(home + "/.cetas/settings.json"))
    assert_eq(fs.exists(home + "/.cetas"), stage == 1)
  }
  let path = "\{home}/.cetas/settings.json"
  fs.write_file(path, "{\"providers\": {}, \"model\": \"zai/glm\"}")
  let (defaults, no_kinds) = load_cetas_subagent_settings(home~)
  assert_eq(defaults, @subagent_kit.SubagentConfig::defaults())
  assert_true(no_kinds.is_empty())
  fs.write_file(
    path,
    (
      #|{"subagent": {
      #|  "default_model": "test/local", "default_effort": "low",
      #|  "kinds": [{"name": "news_search", "description": "Content retrieval",
      #|            "model": "test/fast", "effort": "high"}]}}
    ),
  )
  let (config, kinds) = load_cetas_subagent_settings(home~)
  @debug.assert_eq(config.default_model, Some("test/local"))
  @debug.assert_eq(config.default_effort, Some("low"))
  guard kinds is [kind] else { fail("the configured kind is missing") }
  @debug.assert_eq(kind.name, "news_search")
  @debug.assert_eq(kind.model, Some("test/fast"))
  @debug.assert_eq(kind.effort, Some("high"))
  assert_true(kind.body.contains("{{instructions}}"))
}

///|
async test "subagent settings loader rejects present empty malformed and unreadable files" {
  let fs = @workspace.JsWorkspaceFs()
  let home = "./cetas-subagent-settings-js-" + @cetas_core.mint_session_id()
  let path = home + "/.cetas/settings.json"
  fs.mkdir(home + "/.cetas", recursive=true)
  defer @async.protect_from_cancel(() => fs.remove(home))
  for text in ["", "{broken"] {
    fs.write_file(path, text)
    try load_cetas_subagent_settings(home~) catch {
      error => assert_true(error.to_string().contains("is not valid JSON"))
    } noraise {
      _ => fail("expected present invalid settings to fail")
    }
    assert_eq(fs.read_file(path), text)
  }
  let invalid_kind = "{\"subagent\": {\"kinds\": [{\"name\": \"x\"}]}}"
  fs.write_file(path, invalid_kind)
  try load_cetas_subagent_settings(home~) catch {
    error => assert_true(error.to_string().contains("settings.subagent.kinds"))
  } noraise {
    _ => fail("expected a malformed kind to fail at startup")
  }
  @debug.assert_eq(fs.read_file(path), invalid_kind)
  fs.remove(path)
  fs.mkdir(path, recursive=true)
  try load_cetas_subagent_settings(home~) catch {
    error => assert_true(error.to_string().contains("read failed"))
  } noraise {
    _ => fail("expected unreadable settings to fail")
  }
}
