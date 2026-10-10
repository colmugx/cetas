///|
/// Approval source backed by the web UiPort. Mirrors the cetas-js bridge:
/// category-driven option layout (shell asks offer a whole-tool grant), and
/// every path fails closed on protocol defects.
const APPROVAL_OPTION_ONCE = "Allow once"

///|
const APPROVAL_OPTION_SESSION = "Allow for this session"

///|
const APPROVAL_OPTION_DENY = "Deny"

///|
priv struct UiBlockingApprovalSource {
  ui : &@posoco.UiPort
}

///|
fn UiBlockingApprovalSource::new(
  ui : &@posoco.UiPort,
) -> UiBlockingApprovalSource {
  { ui, }
}

///|
/// Shell asks get four options with the whole-tool grant at index 2; every
/// other category gets three and reports -1 (no tool grant offered).
fn approval_options(
  request : @permission.ApprovalRequest,
) -> (Array[String], Int) {
  let session_label = if request.scopes.length() > 0 {
    "Allow '" + request.scopes.join(", ") + "' for this session"
  } else {
    APPROVAL_OPTION_SESSION
  }
  if request.category == "shell" {
    let tool_label = "Allow all '" +
      request.tool_name +
      "' commands for this session"
    ([APPROVAL_OPTION_ONCE, session_label, tool_label, APPROVAL_OPTION_DENY], 2)
  } else {
    ([APPROVAL_OPTION_ONCE, session_label, APPROVAL_OPTION_DENY], -1)
  }
}

///|
/// A sync `fn` satisfies the async trait slot under MoonBit's
/// colorless-coroutine model: calling `ui.request` suspends until the
/// browser responds.
impl @permission.ApprovalSource for UiBlockingApprovalSource with fn ask(
  self : UiBlockingApprovalSource,
  request : @permission.ApprovalRequest,
) -> @permission.ApprovalDecision {
  let (options, tool_grant_index) = approval_options(request)
  let prompt = "Allow tool '" +
    request.tool_name +
    "' (" +
    request.category +
    ")?\n" +
    request.arguments_preview
  let req : @posoco.UiRequest = @posoco.UiRequest::Select(
    prompt~,
    options~,
    default=Some(0),
  )
  let resp = self.ui.request(req) catch {
    err =>
      return @permission.ApprovalDecision::Deny(
        reason="approval UI failed: " + err.to_string(),
      )
  }
  match resp {
    @posoco.UiResponse::Selected(index) =>
      if index == 0 {
        @permission.ApprovalDecision::AllowOnce
      } else if index == 1 {
        @permission.ApprovalDecision::AllowSession
      } else if index == tool_grant_index && index >= 0 {
        @permission.ApprovalDecision::AllowToolSession
      } else if index == options.length() - 1 {
        @permission.ApprovalDecision::Deny(reason="user declined")
      } else {
        @permission.ApprovalDecision::Deny(
          reason="unexpected ui response to select",
        )
      }
    @posoco.UiResponse::Cancelled =>
      @permission.ApprovalDecision::Deny(reason="user cancelled")
    _ =>
      @permission.ApprovalDecision::Deny(
        reason="unexpected ui response to select",
      )
  }
}
