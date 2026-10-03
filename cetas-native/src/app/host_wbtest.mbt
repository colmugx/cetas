///|
async test "native host routes a real Posoco turn into NativeShell" {
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("native ok")),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let shell = NativeShell::new()
  let observer = NativeShellObserver::new(shell)
  let io = @posoco.ManifestOnly::ManifestOnly(
    @posoco.ExtensionManifest(
      id="native_host_test_io",
      models=[model as &@posoco.ModelPort],
      sessions=[store as &@posoco.SessionStore],
    ),
  )
  let agent = @posoco.Agent(
    exts=[io as &@posoco.Extension, observer as &@posoco.Extension],
    config=@posoco.agent_config(max_tool_rounds=Some(2)),
  )
  let host = NativeHost::from_parts(
    agent,
    shell,
    store as &@posoco.SessionStore,
    "native-host-test",
  )

  ignore(host.run_text_turn("hello native"))
  if shell.status() != ShellIdle ||
    shell.transcript().row_count() != 2 ||
    shell.transcript().row(0).kind != @ui.TranscriptUser ||
    shell.transcript().row(0).text != "hello native" ||
    !shell.transcript().row(0).finalized ||
    shell.transcript().row(1).kind != @ui.TranscriptAssistant ||
    shell.transcript().row(1).text != "native ok" ||
    !shell.transcript().row(1).finalized {
    fail("typed observer did not project the real turn into NativeShell")
  }

  let persisted = store.load("native-host-test")
  assert_eq(persisted.messages.length(), 2)

  host.rewind(1)
  let rewound = store.load("native-host-test")
  assert_eq(rewound.messages.length(), 1)

  host.shutdown()
}

///|
async test "native host enumerates rewind points from physical JSONL lines" {
  let model = @posoco.ScriptedModel([])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let shell = NativeShell::new()
  let io = @posoco.ManifestOnly::ManifestOnly(
    @posoco.ExtensionManifest(
      id="native_host_rewind_io",
      models=[model as &@posoco.ModelPort],
      sessions=[store as &@posoco.SessionStore],
    ),
  )
  let agent = @posoco.Agent(
    exts=[io as &@posoco.Extension],
    config=@posoco.agent_config(max_tool_rounds=Some(1)),
  )
  let root = @fs.tmpdir(prefix="cetas-native-rewind-")
  let session_id = "physical-rewind"
  let path = @fs_session.jsonl_session_path(root, session_id)
  let jsonl = [
    Json::object(Map::from_array([])).stringify(),
    Json::object(
      Map::from_array([
        ("role", Json::string("user")),
        (
          "content",
          Json::array([
            Json::object(
              Map::from_array([
                ("type", Json::string("text")),
                ("text", Json::string("before")),
              ]),
            ),
          ]),
        ),
      ]),
    ).stringify(),
    "{bad",
    "",
    Json::object(
      Map::from_array([
        ("role", Json::string("assistant")),
        ("content", Json::array([])),
      ]),
    ).stringify(),
    Json::object(
      Map::from_array([
        ("role", Json::string("user")),
        (
          "content",
          Json::array([
            Json::object(
              Map::from_array([
                ("type", Json::string("text")),
                ("text", Json::string("after\nline")),
              ]),
            ),
          ]),
        ),
      ]),
    ).stringify(),
  ].join("\n")
  @xfs.write_string_to_file(path, jsonl) catch {
    @xfs.IOError::IOError(detail) =>
      fail("failed to seed physical rewind JSONL: " + detail)
  }

  let host = NativeHost::from_parts(
    agent,
    shell,
    store as &@posoco.SessionStore,
    session_id,
    session_root=Some(root),
  )

  let points = host.rewind_points() catch {
    error =>
      fail("failed to enumerate native rewind points: " + error.to_string())
  }
  assert_eq(points.length(), 2)
  assert_eq(points[0].message_index, 0)
  assert_eq(points[0].preview, "before")
  assert_eq(points[1].message_index, 4)
  assert_eq(points[1].preview, "after line")
  assert_eq(
    host.rewind_user_message(4) catch {
      error => fail("failed to read rewind user text: " + error.to_string())
    },
    Some("after\nline"),
  )

  host.shutdown()
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "native host adopts typed session redirects immediately" {
  let model = @posoco.ScriptedModel([])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let shell = NativeShell::new()
  let state = NativeSessionState::new("session-old")
  let observer = NativeShellObserver::new(shell, session_state=Some(state))
  let io = @posoco.ManifestOnly::ManifestOnly(
    @posoco.ExtensionManifest(
      id="native_host_redirect_io",
      models=[model as &@posoco.ModelPort],
      sessions=[store as &@posoco.SessionStore],
    ),
  )
  let agent = @posoco.Agent(
    exts=[io as &@posoco.Extension, observer as &@posoco.Extension],
    config=@posoco.agent_config(max_tool_rounds=Some(1)),
  )
  let host = NativeHost::from_parts(
    agent,
    shell,
    store as &@posoco.SessionStore,
    "session-old",
    session_state=Some(state),
  )

  observer.on_event(
    @posoco.TurnEvent::SessionRedirect(
      from="session-old",
      to="session-new",
      messages_before=4,
      messages_after=2,
    ),
  )

  assert_eq(host.session_id(), "session-new")
  assert_eq(shell.transcript().row_count(), 1)
  assert_true(shell.transcript().row(0).kind == @ui.TranscriptSystem)
  assert_eq(
    shell.transcript().row(0).text,
    "↻ redirect: session-old → session-new",
  )

  host.shutdown()
}
