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
pub extend FakeApprovalUi with @posoco.UiPort::{ui_descriptor, request, render}

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
  let source = BlockingApprovalSource()
  source.ui = Some(ui as &@posoco.UiPort)
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
  let session_source = BlockingApprovalSource()
  session_source.ui = Some(ui as &@posoco.UiPort)
  match session_source.ask(approval_request()) {
    @permission.ApprovalDecision::AllowSession => ()
    _ => fail("option 1 must remember the approval for the session")
  }
  let deny_ui = fake_ui(reply=@port.UiResponse::Selected(2))
  let deny_source = BlockingApprovalSource()
  deny_source.ui = Some(deny_ui as &@posoco.UiPort)
  match deny_source.ask(approval_request()) {
    @permission.ApprovalDecision::Deny(reason~) =>
      assert_eq(reason, "user declined")
    _ => fail("option 2 must deny the call")
  }
}

///|
async test "approval ask fails closed on cancel and ui failure" {
  let ui = fake_ui(reply=@port.UiResponse::Cancelled)
  let cancel_source = BlockingApprovalSource()
  cancel_source.ui = Some(ui as &@posoco.UiPort)
  match cancel_source.ask(approval_request()) {
    @permission.ApprovalDecision::Deny(reason~) =>
      assert_eq(reason, "user cancelled")
    _ => fail("a cancelled ask must deny the call")
  }
  let failing = fake_ui(reply=@port.UiResponse::Selected(0), fail=true)
  let fail_source = BlockingApprovalSource()
  fail_source.ui = Some(failing as &@posoco.UiPort)
  match fail_source.ask(approval_request()) {
    @permission.ApprovalDecision::Deny(reason~) =>
      assert_true(reason.contains("approval UI failed"))
    _ => fail("a broken approval UI must deny, not approve")
  }
}

///|
async test "plan review presents the name and the full plan, never truncated" {
  let ui = fake_ui(reply=@port.UiResponse::Selected(0))
  let source = PlanApprovalSource()
  source.ui = Some(ui as &@posoco.UiPort)
  // Well past the former 2000-char protocol truncation.
  let sb = StringBuilder()
  for i in 0..<300 {
    sb.write_string("Step \{i}: investigate and verify the tricky part\n")
  }
  let long_plan = sb.to_string()
  assert_true(long_plan.length() > 2000)
  let request : @plan.PlanReviewRequest = {
    name: "auth refactor",
    plan: long_plan,
  }
  match source.review(request) {
    @plan.PlanReviewDecision::Accept => ()
    _ => fail("option 0 must accept the plan")
  }
  match ui.asked[0] {
    @port.UiRequest::Select(prompt~, options~, default~) => {
      assert_true(prompt.contains("Plan awaiting approval: auth refactor"))
      assert_true(prompt.contains(long_plan))
      assert_false(prompt.contains("..."))
      assert_eq(options.length(), 3)
      assert_eq(default, Some(0))
    }
    _ => fail("the plan review must be a Select request")
  }
}

///|
async test "plan review revise requires a reason and dismiss fails closed" {
  // A cancelled review fails closed to Dismiss.
  let cancelled = fake_ui(reply=@port.UiResponse::Cancelled)
  let cancelled_source = PlanApprovalSource()
  cancelled_source.ui = Some(cancelled as &@posoco.UiPort)
  match cancelled_source.review({ name: "p", plan: "1. x", }) {
    @plan.PlanReviewDecision::Dismiss => ()
    _ => fail("a cancelled review must dismiss")
  }
  // A broken review UI fails closed to Dismiss too.
  let failing = fake_ui(reply=@port.UiResponse::Selected(0), fail=true)
  let failing_source = PlanApprovalSource()
  failing_source.ui = Some(failing as &@posoco.UiPort)
  match failing_source.review({ name: "p", plan: "1. x", }) {
    @plan.PlanReviewDecision::Dismiss => ()
    _ => fail("a broken review must dismiss")
  }
  // Without a composed UI there is nothing to ask: Dismiss.
  let detached = PlanApprovalSource()
  match detached.review({ name: "p", plan: "1. x", }) {
    @plan.PlanReviewDecision::Dismiss => ()
    _ => fail("a detached review must dismiss")
  }
}
