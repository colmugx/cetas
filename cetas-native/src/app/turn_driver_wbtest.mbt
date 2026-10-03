///|
async test "native turn driver runs Agent without blocking editor state" {
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("driver ok")),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let shell = NativeShell::new()
  let observer = NativeShellObserver::new(shell)
  let io = @posoco.ManifestOnly::ManifestOnly(
    @posoco.ExtensionManifest(
      id="native_turn_driver_io",
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
    "native-turn-driver",
  )
  let editor = @ui.EditorModel::new()
  editor.set_text("  hello driver  ")
  let driver = NativeTurnDriver::new(host, editor)

  @async.with_task_group(group => {
    assert_true(driver.submit(group, editor.text()) == PromptStarted)
    assert_true(driver.is_running())
    assert_eq(editor.text(), "")
    assert_eq(editor.history_length(), 1)

    let mut settled = false
    for _ in 0..<64 {
      @async.pause()
      if driver.poll_settle(group) {
        settled = true
        break
      }
    }
    assert_true(settled)
    assert_false(driver.is_running())

    assert_true(shell.status() == ShellIdle)
    assert_eq(shell.transcript().row_count(), 2)
    assert_true(shell.transcript().row(0).kind == @ui.TranscriptUser)
    assert_eq(shell.transcript().row(0).text, "hello driver")
    assert_true(shell.transcript().row(1).kind == @ui.TranscriptAssistant)
    assert_eq(shell.transcript().row(1).text, "driver ok")

    let persisted = store.load("native-turn-driver")
    assert_eq(persisted.messages.length(), 2)
  })

  driver.shutdown()
}
