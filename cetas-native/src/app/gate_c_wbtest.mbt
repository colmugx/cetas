/// Gate C contract tests.
///
/// Gate C means the native host remains useful before an Agent exists and
/// presents extension UI through the common UiPort boundary.

///|
test "gate C setup shell exposes only recovery commands" {
  let login = setup_completion_items("/l")
  assert_eq(login.length(), 1)
  assert_eq(login[0].value, "/login")
  let retry = setup_completion_items("/r")
  assert_eq(retry.length(), 1)
  assert_eq(retry[0].value, "/retry")
  assert_eq(setup_login_provider("/login openai"), Ok("openai"))
  assert_true(setup_login_provider("/login openai oauth") is Err(_))
}

///|
test "gate C extension render mount preserves keyed replacement" {
  let model = NativeUiRenderModel::new()
  model.apply(
    @posoco.UiRender::{
      slot: @posoco.UiSlot::Notice,
      key: "oauth",
      title: Some("OAuth"),
      body: @posoco.UiBody::Lines([
        "Open https://example.invalid/device",
        "Code ABCD-EFGH",
      ]),
      ttl_ms: None,
    },
  )
  assert_eq(model.line_count(), 3)
  model.apply(
    @posoco.UiRender::{
      slot: @posoco.UiSlot::Notice,
      key: "oauth",
      title: Some("OAuth"),
      body: @posoco.UiBody::Text("Waiting for authorization"),
      ttl_ms: None,
    },
  )
  assert_eq(model.line_count(), 2)
  assert_eq(model.line(0), Some("! OAuth"))
  assert_eq(model.line(1), Some("! Waiting for authorization"))
}

///|
async test "gate C native UiPort renders and requests through one controller" {
  @async.with_task_group() <| group => {
    let ui = NativeUiPort::new()
    let controller = NativeUiController::new(ui)
    ui.render(
      @posoco.UiRender::{
        slot: @posoco.UiSlot::Status,
        key: "setup",
        title: None,
        body: @posoco.UiBody::Text("setup required"),
        ttl_ms: None,
      },
    )
    assert_false(controller.pump())
    assert_eq(controller.render_line_count(), 1)
    assert_eq(controller.render_line(0), Some("· setup required"))

    let waiter = group.spawn(
      () =>
        (ui as &@posoco.UiPort).request(
          @posoco.UiRequest::Select(
            prompt="Choose provider",
            options=["OpenAI", "Kimi"],
            default=Some(0),
          ),
        ),
      allow_failure=true,
    )
    @async.sleep(0)
    assert_true(controller.pump())
    assert_eq(controller.active_prompt(), Some("Choose provider"))
    assert_eq(controller.active_option_count(), 2)
    // Cancellation is sufficient to prove the same controller releases the
    // suspended request; detailed keyboard selection has its own wbtests.
    assert_true(controller.cancel_active())
    assert_eq(waiter.wait(), @posoco.UiResponse::Cancelled)
    controller.close()
  }
}


///|
test "gate C secret prompts mask display without corrupting submitted value" {
  let panel = UiRequestPanelModel::new(
    @posoco.UiRequest::Input(
      prompt=native_secret_prompt("API key"),
      default=None,
    ),
  )
  assert_true(panel.kind() == UiPanelSecretInput)
  assert_eq(panel.prompt(), "API key")
  panel.handle_paste("sk-secret")
  assert_eq(panel.input_text(), "sk-secret")
  assert_eq(panel.display_input_text(), "•••••••••")
  assert_false(panel.display_input_text().contains("secret"))
}

///|
test "gate C OAuth interaction projects URL device code and progress into mounts" {
  let ui = NativeUiPort::new()
  let controller = NativeUiController::new(ui)
  let auth = NativeAuthUi::new(ui)

  auth.notify(@oauth.AuthMessage::AuthUrl("https://example.invalid/auth"))
  assert_false(controller.pump())
  assert_eq(controller.render_line(0), Some("! OAuth"))
  assert_eq(
    controller.render_line(2),
    Some("! https://example.invalid/auth"),
  )

  auth.notify(
    @oauth.AuthMessage::DeviceCode(
      "https://example.invalid/device",
      "ABCD-EFGH",
    ),
  )
  assert_false(controller.pump())
  assert_eq(controller.render_line(0), Some("! OAuth device login"))
  assert_eq(controller.render_line(3), Some("! Code: ABCD-EFGH"))

  auth.notify(@oauth.AuthMessage::Progress("Waiting for authorization"))
  assert_false(controller.pump())
  let mut saw_progress = false
  for index in 0..<controller.render_line_count() {
    if controller.render_line(index) == Some("· Waiting for authorization") {
      saw_progress = true
    }
  }
  assert_true(saw_progress)
  controller.close()
}

///|
test "gate C subagent events project useful activity states" {
  let started : @subagent_kit.SubagentEvent = {
    child_session: "subagent-1",
    kind: "coder",
    parent_call: "call-1",
    event: @posoco.TurnEvent::TurnStarted,
  }
  assert_eq(native_subagent_event_detail(started), Some("running"))

  let pending : @subagent_kit.SubagentEvent = {
    child_session: "subagent-1",
    kind: "coder",
    parent_call: "call-1",
    event: @posoco.TurnEvent::ToolCallPending(
      @posoco.ToolCall::{
        call_id: @posoco.CallId::unchecked("child-call"),
        name: @posoco.ToolName::unchecked("read"),
        arguments: Json::object(Map::from_array([])),
      },
    ),
  }
  assert_eq(
    native_subagent_event_detail(pending),
    Some("running · read"),
  )

  let terminal : @subagent_kit.SubagentEvent = {
    child_session: "subagent-1",
    kind: "coder",
    parent_call: "background",
    event: @posoco.TurnEvent::Custom(
      source="posoco_ext_subagent",
      label="background_terminal",
      data=Json::object(
        Map::from_array([("state", Json::string("completed"))]),
      ),
    ),
  }
  assert_eq(
    native_subagent_event_detail(terminal),
    Some("background_terminal · completed"),
  )
}
