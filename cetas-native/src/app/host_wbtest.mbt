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
    exts=[
      io as &@posoco.Extension,
      observer as &@posoco.Extension,
    ],
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
