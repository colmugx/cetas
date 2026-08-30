///|
/// Fake UiPort recording every ask; `reply` (or `fail`) decides the answer.
struct FakeApprovalUi {
  asked : Array[@port.UiRequest]
  reply : @port.UiResponse
  fail : Bool
}

///|
pub impl @posoco.UiPort for FakeApprovalUi with fn ui_descriptor(
  _self : FakeApprovalUi,
) -> @port.UiDescriptor {
  @port.UiDescriptor::empty()
}

///|
pub impl @posoco.UiPort for FakeApprovalUi with fn render(
  _self : FakeApprovalUi,
  _intent : @port.UiRender,
) -> Unit {
  ()
}

///|
pub impl @posoco.UiPort for FakeApprovalUi with fn request(
  self : FakeApprovalUi,
  req : @port.UiRequest,
) -> @port.UiResponse {
  self.asked.push(req)
  if self.fail {
    raise @error.UiError::IoFailure(detail="callback rejected")
  }
  self.reply
}

///|
fn fake_ui(reply~ : @port.UiResponse, fail? : Bool = false) -> FakeApprovalUi {
  { asked: [], reply, fail, }
}

///|
fn approval_request() -> @permission.ApprovalRequest {
  {
    tool_name: "bash",
    call_id: "call-1",
    category: "shell",
    arguments_preview: "{\"cmd\":\"ls -la\"}",
    arguments: Json::object({ "cmd": Json::string("ls -la") }),
  }
}

///|
async test "approval ask presents the full decision space as a select" {
  let ui = fake_ui(reply=@port.UiResponse::Selected(0))
  let source = BlockingApprovalSource(ui as &@posoco.UiPort)
  match source.ask(approval_request()) {
    @permission.ApprovalDecision::AllowOnce => ()
    _ => fail("option 0 must approve this call only")
  }
  match ui.asked[0] {
    @port.UiRequest::Select(prompt~, options~, default~) => {
      assert_eq(prompt, "Allow tool 'bash' (shell)?\n{\"cmd\":\"ls -la\"}")
      assert_eq(options.length(), 3)
      assert_eq(options[0], "Allow once")
      assert_eq(options[1], "Allow for this session")
      assert_eq(options[2], "Deny")
      assert_eq(default, Some(0))
    }
    _ => fail("the approval ask must be a Select request")
  }
}

///|
async test "approval ask maps the session and deny options" {
  let ui = fake_ui(reply=@port.UiResponse::Selected(1))
  match BlockingApprovalSource(ui as &@posoco.UiPort).ask(approval_request()) {
    @permission.ApprovalDecision::AllowSession => ()
    _ => fail("option 1 must remember the approval for the session")
  }
  let deny_ui = fake_ui(reply=@port.UiResponse::Selected(2))
  match
    BlockingApprovalSource(deny_ui as &@posoco.UiPort).ask(approval_request()) {
    @permission.ApprovalDecision::Deny(reason~) =>
      assert_eq(reason, "user declined")
    _ => fail("option 2 must deny the call")
  }
}

///|
async test "approval ask fails closed on cancel and ui failure" {
  let ui = fake_ui(reply=@port.UiResponse::Cancelled)
  match BlockingApprovalSource(ui as &@posoco.UiPort).ask(approval_request()) {
    @permission.ApprovalDecision::Deny(reason~) =>
      assert_eq(reason, "user cancelled")
    _ => fail("a cancelled ask must deny the call")
  }
  let failing = fake_ui(reply=@port.UiResponse::Selected(0), fail=true)
  match
    BlockingApprovalSource(failing as &@posoco.UiPort).ask(approval_request()) {
    @permission.ApprovalDecision::Deny(reason~) =>
      assert_true(reason.contains("approval UI failed"))
    _ => fail("a broken approval UI must deny, not approve")
  }
}
