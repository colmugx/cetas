///|
async test "subagent first use accepts missing settings without creating files" {
  let fs = @workspace.JsWorkspaceFs()
  let home = "./cetas-subagent-settings-js-" + @cetas_core.mint_session_id()
  fs.mkdir(home, recursive=true)
  errdefer fs.remove(home)
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
}

///|
async test "subagent settings loader rejects present empty malformed and unreadable files" {
  let fs = @workspace.JsWorkspaceFs()
  let home = "./cetas-subagent-settings-js-" + @cetas_core.mint_session_id()
  let path = home + "/.cetas/settings.json"
  fs.mkdir(home + "/.cetas", recursive=true)
  errdefer fs.remove(home)
  for text in ["", "{broken"] {
    fs.write_file(path, text)
    try load_cetas_subagent_settings(home~) catch {
      error => assert_true(error.to_string().contains("is not valid JSON"))
    } noraise {
      _ => fail("expected present invalid settings to fail")
    }
    assert_eq(fs.read_file(path), text)
  }
  fs.remove(path)
  fs.mkdir(path, recursive=true)
  try load_cetas_subagent_settings(home~) catch {
    error => assert_true(error.to_string().contains("read failed"))
  } noraise {
    _ => fail("expected unreadable settings to fail")
  }
}
