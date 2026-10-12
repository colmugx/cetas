///|
async test "subagent first use accepts missing settings without creating files" {
  let fs = @workspace.NativeWorkspaceFs()
  let home = @fs.tmpdir(prefix="cetas-subagent-settings-")
  errdefer (@fs.rmdir(home, recursive=true) catch { _ => () })
  for stage in 0..<2 {
    if stage == 1 {
      fs.mkdir(home + "/.cetas", recursive=true)
    }
    let (config, kinds) = load_cetas_subagent_settings(fs, home~)
    assert_eq(config, @subagent_kit.SubagentConfig::defaults())
    assert_eq(kinds.length(), 0)
    assert_false(fs.exists(home + "/.cetas/settings.json"))
    assert_eq(fs.exists(home + "/.cetas"), stage == 1)
  }
}

///|
async test "subagent settings loader rejects present empty malformed and unreadable files" {
  let fs = @workspace.NativeWorkspaceFs()
  let home = @fs.tmpdir(prefix="cetas-subagent-settings-")
  errdefer (@fs.rmdir(home, recursive=true) catch { _ => () })
  let path = home + "/.cetas/settings.json"
  fs.mkdir(home + "/.cetas", recursive=true)
  for text in ["", "{broken"] {
    fs.write_file(path, text)
    try load_cetas_subagent_settings(fs, home~) catch {
      error => assert_true(error.to_string().contains("is not valid JSON"))
    } noraise {
      _ => fail("expected present invalid settings to fail")
    }
    assert_eq(fs.read_file(path), text)
  }
  fs.remove(path)
  fs.mkdir(path, recursive=true)
  try load_cetas_subagent_settings(fs, home~) catch {
    error => assert_true(error.to_string().contains("read failed"))
  } noraise {
    _ => fail("expected unreadable settings to fail")
  }
}
