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

// ──────────────────────────────────────────────────────────────────────────
// Plan review surface
// ──────────────────────────────────────────────────────────────────────────

///|
/// Plan review for the js host: renders the submitted plan and asks for a
/// verdict through the same UiPort modal surface the permission approvals
/// and ask_question use. Approve accepts and starts implementation; Revise
/// asks for the (required) reason with a follow-up input; Dismiss — or
/// cancelling either modal — cancels the plan and stops the turn.
pub(all) struct PlanApprovalSource {
  ui : &@posoco.UiPort
}

///|
pub fn PlanApprovalSource::PlanApprovalSource(
  ui : &@posoco.UiPort,
) -> PlanApprovalSource {
  { ui, }
}

///|
const PLAN_OPTION_APPROVE = "Approve — accept the plan and implement it"

///|
const PLAN_OPTION_REVISE = "Revise — send the plan back with feedback"

///|
const PLAN_OPTION_DISMISS = "Dismiss — cancel the plan and stop"

///|
pub impl @plan.PlanReviewSource for PlanApprovalSource with fn review(
  self,
  request : @plan.PlanReviewRequest,
) -> @plan.PlanReviewDecision {
  let plan_preview = if request.plan.length() <= 2000 {
    request.plan
  } else {
    request.plan.sub(end=1997).to_owned() + "..."
  }
  let prompt = "Plan submitted for approval:\n\n" +
    plan_preview +
    "\n\nAccept, revise with feedback, or dismiss?"
  let req : @posoco.UiRequest = @posoco.UiRequest::Select(
    prompt~,
    options=[PLAN_OPTION_APPROVE, PLAN_OPTION_REVISE, PLAN_OPTION_DISMISS],
    default=Some(0),
  )
  let resp = self.ui.request(req) catch {
    _ => return @plan.PlanReviewDecision::Dismiss
  }
  match resp {
    @posoco.UiResponse::Selected(0) => @plan.PlanReviewDecision::Accept
    @posoco.UiResponse::Selected(1) => {
      // Revision always carries a reason; an empty input or a cancelled
      // prompt cancels the plan instead of sending it back blind.
      let reason_req : @posoco.UiRequest = @posoco.UiRequest::Input(
        prompt="Why is the plan sent back? (required feedback for the model)",
        default=Some(""),
      )
      let reason_resp = self.ui.request(reason_req) catch {
        _ => return @plan.PlanReviewDecision::Dismiss
      }
      match reason_resp {
        @posoco.UiResponse::Text(reason) =>
          if reason.trim().length() == 0 {
            @plan.PlanReviewDecision::Dismiss
          } else {
            @plan.PlanReviewDecision::Revise(feedback=reason)
          }
        _ => @plan.PlanReviewDecision::Dismiss
      }
    }
    _ => @plan.PlanReviewDecision::Dismiss
  }
}
