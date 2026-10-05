/// Gate B contract tests.
///
/// These tests exercise the daily-use product adapters rather than only
/// renderer primitives. A regression in model/effort, skills, sessions,
/// file mentions, tool presentation, or thinking controls must fail native
/// app tests.

///|
test "gate B catalogs produce executable model effort skill and session inputs" {
  let model_items = model_catalog_items(
    Json::array([
      Json::object(
        Map::from_array([
          ("id", Json::string("openai/gpt-5")),
          ("label", Json::string("GPT-5")),
          ("active", Json::boolean(true)),
          (
            "thinking_efforts",
            Json::array([Json::string("medium"), Json::string("high")]),
          ),
        ]),
      ),
      Json::object(
        Map::from_array([
          ("id", Json::string("kimi/k2")),
          ("label", Json::string("Kimi K2")),
          ("active", Json::boolean(false)),
          ("thinking_efforts", Json::array([])),
        ]),
      ),
    ]),
  )
  assert_eq(model_items.length(), 3)
  assert_eq(model_items[0].value, "/model openai/gpt-5 medium")
  assert_eq(model_items[1].value, "/model openai/gpt-5 high")
  assert_eq(model_items[2].value, "/model kimi/k2")
  assert_true(model_items[0].label.contains("* GPT-5"))
  assert_true(model_items[0].label.contains("effort: medium"))

  let skill_items = skills_catalog_items(
    Json::object(
      Map::from_array([
        ("kind", Json::string("skills_catalog")),
        (
          "skills",
          Json::array([
            Json::object(
              Map::from_array([
                ("name", Json::string("review")),
                ("description", Json::string("Review the current change")),
                ("scope", Json::string("project")),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  )
  assert_eq(skill_items.length(), 1)
  assert_eq(skill_items[0].value, "$review")
  assert_true(skill_items[0].label.contains("[project] review"))

  let session_items = session_catalog_items(
    Json::object(
      Map::from_array([
        ("kind", Json::string("session_catalog")),
        (
          "sessions",
          Json::array([
            Json::object(
              Map::from_array([
                ("id", Json::string("cetas-2")),
                ("current", Json::boolean(true)),
              ]),
            ),
            Json::object(
              Map::from_array([
                ("id", Json::string("cetas-1")),
                ("current", Json::boolean(false)),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  )
  assert_eq(session_items.length(), 2)
  assert_eq(session_items[0].value, "/resume cetas-2")
  assert_true(session_items[0].label.contains("* cetas-2"))
  assert_eq(session_items[1].value, "/resume cetas-1")
}

///|
test "gate B tool and thinking presentation are user controllable" {
  let shell = NativeShell::new()
  shell.begin_turn()
  shell.append_reasoning("line one\nline two\nline three\nline four")
  shell.tool_call_started(
    "call-1", "bash", "{\"command\":\"moon test\",\"description\":\"run native tests\"}",
  )

  let tool_row = shell.transcript().row(1)
  assert_true(tool_row.text.has_prefix("● bash "))
  assert_true(tool_row.text.contains("moon test"))

  assert_false(shell.thinking_expanded())
  assert_true(shell.toggle_thinking_expanded())
  assert_true(shell.thinking_expanded())

  assert_false(shell.tool_output_expanded())
  assert_true(shell.toggle_tool_output_expanded())
  assert_true(shell.tool_output_expanded())
  assert_true(shell.transcript().row(1).text.has_prefix("● bash\n"))

  shell.tool_call_completed("call-1", "first\nsecond\nthird\nfourth", false)
  let result_row = shell.transcript().row(1)
  assert_true(result_row.finalized)
  assert_true(result_row.text.has_prefix("✓ bash\n"))
  assert_true(result_row.text.contains("fourth"))
}

///|
async test "gate B file mentions rank and insert workspace paths" {
  let ranked = rank_file_mention_items(
    ["src/", "src/main.mbt", "src/app/runtime.mbt", "docs/main.md", "README.md"],
    "main",
  )
  assert_eq(ranked.length(), 2)
  assert_eq(ranked[0], "src/main.mbt")
  assert_eq(ranked[1], "docs/main.md")

  let host_model = @posoco.ScriptedModel([])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let io = @posoco.ManifestOnly::ManifestOnly(
    @posoco.ExtensionManifest(
      id="gate_b_file_io",
      models=[host_model as &@posoco.ModelPort],
      sessions=[store as &@posoco.SessionStore],
    ),
  )
  let agent = @posoco.Agent(
    exts=[io as &@posoco.Extension],
    config=@posoco.agent_config(max_tool_rounds=Some(1)),
  )
  let host = NativeHost::from_parts(
    agent,
    NativeShell::new(),
    store as &@posoco.SessionStore,
    "gate-b-file",
    workspace_files=["src/", "src/main.mbt", "README.md"],
  )
  guard host.command_autocomplete("@main") is Some((prefix, items)) else {
    fail("Gate B requires @file completion")
  }
  assert_eq(prefix, "@main")
  assert_eq(items.length(), 1)
  assert_eq(items[0].value, "@src/main.mbt ")
  host.shutdown()
}

///|
async test "gate B normal-session slash routes stay local and executable" {
  let local_items = native_local_command_items("")
  let values = local_items.map(item => item.value)
  assert_true(values.contains("/new"))
  assert_true(values.contains("/sessions"))
  assert_true(values.contains("/resume"))
  assert_true(values.contains("/rewind"))
  assert_true(values.contains("/compact"))
  assert_true(values.contains("/exit"))

  let model = @posoco.ScriptedModel([])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let io = @posoco.ManifestOnly::ManifestOnly(
    @posoco.ExtensionManifest(
      id="gate_b_session_io",
      models=[model as &@posoco.ModelPort],
      sessions=[store as &@posoco.SessionStore],
    ),
  )
  let agent = @posoco.Agent(
    exts=[io as &@posoco.Extension],
    config=@posoco.agent_config(max_tool_rounds=Some(1)),
  )
  let root = @fs.tmpdir(prefix="cetas-native-gate-b-sessions-")
  let current = "cetas-current"
  @xfs.write_string_to_file(@fs_session.jsonl_session_path(root, current), "") catch {
    @xfs.IOError::IOError(detail) =>
      fail("failed to seed current session: " + detail)
  }
  @xfs.write_string_to_file(
    @fs_session.jsonl_session_path(root, "cetas-older"),
    "",
  ) catch {
    @xfs.IOError::IOError(detail) =>
      fail("failed to seed older session: " + detail)
  }
  let host = NativeHost::from_parts(
    agent,
    NativeShell::new(),
    store as &@posoco.SessionStore,
    current,
    session_root=Some(root),
  )

  match host.invoke_slash_command("/sessions") {
    @posoco.CommandOutcome::Success(structured~, ..) => {
      guard structured is Some(value) else {
        fail("/sessions must return a catalog")
      }
      let items = session_catalog_items(value)
      assert_eq(items.length(), 2)
      assert_true(items[0].value.has_prefix("/resume "))
    }
    _ => fail("/sessions must execute locally")
  }

  match host.invoke_slash_command("/resume cetas-older") {
    @posoco.CommandOutcome::Success(..) => ()
    _ => fail("/resume must execute locally")
  }
  assert_eq(host.session_id(), "cetas-older")

  match host.invoke_slash_command("/new") {
    @posoco.CommandOutcome::Success(..) => ()
    _ => fail("/new must execute locally")
  }
  assert_true(host.session_id().has_prefix("cetas-"))
  assert_true(host.session_id() != "cetas-older")

  host.shutdown()
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}
