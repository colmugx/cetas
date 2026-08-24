///|
/// Parse the `permission_mode` config string. Unrecognized values fall back
/// to `WorkspaceWrite` so a typo never accidentally widens to `Interactive`
/// or `Yolo`, or locks down to `ReadOnly`.
fn parse_permission_mode(raw : String) -> @permission.PermissionMode {
  match raw {
    "readonly" => @permission.ReadOnly
    "workspace_write" => @permission.WorkspaceWrite
    "interactive" => @permission.Interactive
    "yolo" => @permission.Yolo
    _ => @permission.WorkspaceWrite
  }
}

///|
/// Option labels presented for every approval ask. Index-coupled with the
/// decision mapping in `BlockingApprovalSource::ask`: 0 = approve this call
/// only, 1 = approve and remember for this agent lifetime (per the policy's
/// session-scope cache), 2 = deny.
const APPROVAL_OPTION_ONCE = "Allow once"

///|
const APPROVAL_OPTION_SESSION = "Allow for this session"

///|
const APPROVAL_OPTION_DENY = "Deny"

///|
/// JS-host approval source for `posoco-ext-permission`.
///
/// `ApprovalSource::ask` is an `async fn` (because `Hook::before_tool` is
/// `async`). This impl is declared `fn ask` — a sync `fn` satisfies an
/// `async fn` trait slot under MoonBit's colorless-coroutine model — and
/// calls the async `UiPort::request` bare, which suspends the enclosing
/// coroutine until the JS Promise resolves. The same sync-fn-satisfies-
/// async-slot pattern is used by `JsUiPort::request` itself.
///
/// The ask is data-driven over the port's decision vocabulary: the UI
/// presents ext-permission's full decision space (`AllowOnce`,
/// `AllowSession`, `Deny`) and the host maps the picked index onto the
/// matching `ApprovalDecision` — no option is collapsed away. Deny is
/// terminal for the turn (the reason flows into the turn error); a denied
/// tool never becomes a silent skip.
pub(all) struct BlockingApprovalSource {
  ui : &@posoco.UiPort
}

///|
pub fn BlockingApprovalSource::BlockingApprovalSource(
  ui : &@posoco.UiPort,
) -> BlockingApprovalSource {
  { ui, }
}

///|
pub impl @permission.ApprovalSource for BlockingApprovalSource with fn ask(
  self : BlockingApprovalSource,
  request : @permission.ApprovalRequest,
) -> @permission.ApprovalDecision {
  let prompt = "Allow tool '" +
    request.tool_name +
    "' (" +
    request.category +
    ")?\n" +
    request.arguments_preview
  let req : @posoco.UiRequest = @posoco.UiRequest::Select(
    prompt~,
    options=[
      APPROVAL_OPTION_ONCE,
      APPROVAL_OPTION_SESSION,
      APPROVAL_OPTION_DENY,
    ],
    default=Some(0),
  )
  let resp = self.ui.request(req) catch {
    err =>
      return @permission.ApprovalDecision::Deny(
        reason="approval UI failed: " + err.to_string(),
      )
  }
  match resp {
    @posoco.UiResponse::Selected(0) => @permission.ApprovalDecision::AllowOnce
    @posoco.UiResponse::Selected(1) =>
      @permission.ApprovalDecision::AllowSession
    @posoco.UiResponse::Selected(2) =>
      @permission.ApprovalDecision::Deny(reason="user declined")
    @posoco.UiResponse::Cancelled =>
      @permission.ApprovalDecision::Deny(reason="user cancelled")
    // Select yields Selected/Cancelled only; anything else is a protocol
    // defect, and a defective ask fails closed.
    _ =>
      @permission.ApprovalDecision::Deny(
        reason="unexpected ui response to select",
      )
  }
}
