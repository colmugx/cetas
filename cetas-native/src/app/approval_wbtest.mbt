///|
fn native_approval_request() -> @permission.ApprovalRequest {
  {
    tool_name: "write",
    call_id: "call-1",
    category: "write",
    arguments_preview: "{\"path\":\"a\"}",
  }
}

///|
async test "native approval source suspends on UiPort and maps selection" {
  let ui = NativeUiPort::new()
  let approval = NativeApprovalSource::new()
  approval.ui = Some(ui as &@posoco.UiPort)

  @async.with_task_group(group => {
    let decision = group.spawn(async fn() {
      approval.ask(native_approval_request())
    })

    let pending = take_pending_ui_request(ui)
    match pending.request() {
      @posoco.UiRequest::Select(prompt~, options~, default~) => {
        assert_true(prompt.contains("write"))
        assert_eq(options.length(), 3)
        assert_eq(options[0], "Allow once")
        assert_eq(options[1], "Allow for this session")
        assert_eq(options[2], "Deny")
        assert_eq(default, Some(0))
      }
      _ => fail("approval must publish a Select request")
    }
    assert_true(pending.respond(@posoco.UiResponse::Selected(1)))

    match decision.wait() {
      @permission.ApprovalDecision::AllowSession => ()
      _ => fail("Selected(1) must map to AllowSession")
    }
  })

  @async.with_task_group(group => {
    let decision = group.spawn(async fn() {
      approval.ask(native_approval_request())
    })
    let pending = take_pending_ui_request(ui)
    assert_true(pending.respond(@posoco.UiResponse::Cancelled))
    match decision.wait() {
      @permission.ApprovalDecision::Deny(reason~) =>
        assert_eq(reason, "user cancelled")
      _ => fail("Cancelled must deny approval")
    }
  })
}

///|
test "native approval denies before composed UiPort is available" {
  let approval = NativeApprovalSource::new()
  match approval.ask(native_approval_request()) {
    @permission.ApprovalDecision::Deny(reason~) =>
      assert_true(reason.contains("not composed"))
    _ => fail("uncomposed approval source must deny")
  }
}
