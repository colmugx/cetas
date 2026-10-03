///|
fn native_request_event_labels(
  events : Array[@posoco.TurnEvent],
) -> Array[String] {
  let labels : Array[String] = []
  for event in events {
    match event {
      @posoco.TurnEvent::UserRequestStarted(kind~, prompt~) =>
        labels.push("started(" + kind + "," + prompt + ")")
      @posoco.TurnEvent::UserRequestFinished(kind~, outcome~) =>
        labels.push("finished(" + kind + "," + outcome + ")")
      _ => ()
    }
  }
  labels
}

///|
async test "native approval uses composed UiPort lifecycle wrapper" {
  let raw_ui = NativeUiPort::new()
  let approval = NativeApprovalSource::new()
  let bridge = NativeUiBridge::new(approval)
  let observer = @posoco.RecordingObserver::RecordingObserver()
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("unused")),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let base = @posoco.ManifestOnly::ManifestOnly(
    @posoco.ExtensionManifest(
      id="native_ui_composition_test",
      models=[model as &@posoco.ModelPort],
      sessions=[store as &@posoco.SessionStore],
      observers=[observer as &@posoco.Observer],
    ),
  )
  let ui_ext = @cetas_core.UiPortExtension::UiPortExtension(
    id="native_ui_test_port",
    ui=raw_ui as &@posoco.UiPort,
  )
  let agent = @posoco.Agent(
    exts=[
      base as &@posoco.Extension,
      ui_ext as &@posoco.Extension,
      bridge as &@posoco.Extension,
    ],
    config=@posoco.agent_config(max_tool_rounds=Some(1)),
  )

  @async.with_task_group(group => {
    let decision = group.spawn(async fn() {
      approval.ask(native_approval_request())
    })

    let pending = take_pending_ui_request(raw_ui)
    match pending.request() {
      @posoco.UiRequest::Select(prompt~, options~, default~) => {
        assert_true(prompt.contains("write"))
        assert_eq(options.length(), 3)
        assert_eq(default, Some(0))
      }
      _ => fail("composed approval must reach raw NativeUiPort as Select")
    }
    assert_true(pending.respond(@posoco.UiResponse::Selected(0)))

    match decision.wait() {
      @permission.ApprovalDecision::AllowOnce => ()
      _ => fail("Selected(0) must map to AllowOnce")
    }
  })

  let labels = native_request_event_labels(observer.events())
  assert_eq(labels.length(), 2)
  assert_true(labels[0].contains("started(select,"))
  assert_eq(labels[1], "finished(select,answered)")

  agent.shutdown()
}
