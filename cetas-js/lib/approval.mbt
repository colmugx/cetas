///|
/// Parse the `permission_mode` config string. The UNSET default is `Yolo`
/// (the host bridge fills it in); an unrecognized value still falls back to
/// `WorkspaceWrite` so a typo never accidentally widens to `Interactive` or
/// `Yolo`, or locks down to `ReadOnly`. `Auto` needs a composed
/// DecisionPort — without one the policy fails composition loudly instead
/// of silently degrading.
fn parse_permission_mode(raw : String) -> @permission.PermissionMode {
  match raw {
    "readonly" => @permission.ReadOnly
    "workspace_write" => @permission.WorkspaceWrite
    "interactive" => @permission.Interactive
    "auto" => @permission.Auto
    "yolo" => @permission.Yolo
    _ => @permission.WorkspaceWrite
  }
}

///|
/// Fixed labels for the ends of every approval ask's option list. The
/// session label is category-driven (see `approval_options`) so it names
/// exactly what the grant would remember. Index-coupled with the decision
/// mapping in `BlockingApprovalSource::ask`.
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
/// The ask is data-driven over the port's decision vocabulary, and the
/// option layout is category-driven so every session option names exactly
/// what it would remember (issue #1: "Allow for this session" used to read
/// as a tool-level grant while the policy cached only the command scope):
///
/// - shell asks present four options: once; the concrete scope(s) granted
///   (e.g. `Allow 'bash:ls' for this session`; the generic label when the
///   command has no parseable scope); an explicit whole-tool grant
///   (`Allow all 'bash' commands for this session`); deny.
/// - write/unknown asks present three: once; the tool itself (their cache
///   key already is the bare tool name); deny.
/// - semantic-risk and escalated asks present three and never offer a
///   standing grant — those paths deliberately avoid session memory.
///
/// Deny is non-terminal steering: the pump folds the rejection into a
/// `NotExecuted(RejectedByHook)` tool result and the turn continues, so
/// the model sees the deny reason and can choose a different action rather
/// than the turn ending in an error.
pub(all) struct BlockingApprovalSource {
  /// The composed UiPort, wired by the ui bridge extension at composition
  /// time. Empty only if composition never ran; the ask fails closed.
  mut ui : &@posoco.UiPort?
}

///|
pub fn BlockingApprovalSource::BlockingApprovalSource() -> BlockingApprovalSource {
  { ui: None, }
}

///|
/// Build the option list and the index of the whole-tool grant option.
/// Shell asks get four options with the tool grant at index 2; every other
/// category gets three and reports -1 (no tool grant offered).
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
  let ui = match self.ui {
    Some(ui) => ui
    None =>
      return @permission.ApprovalDecision::Deny(
        reason="denied: approval UI not composed yet",
      )
  }
  let (options, tool_grant_index) = approval_options(request)
  let req : @posoco.UiRequest = @posoco.UiRequest::Select(
    prompt~,
    options~,
    default=Some(0),
  )
  let resp = ui.request(req) catch {
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
      } else if index == tool_grant_index {
        @permission.ApprovalDecision::AllowToolSession
      } else if index == options.length() - 1 {
        @permission.ApprovalDecision::Deny(reason="user declined")
      } else {
        // Out-of-range indices are a protocol defect; a defective ask
        // fails closed.
        @permission.ApprovalDecision::Deny(
          reason="unexpected ui response to select",
        )
      }
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
/// and ask_question use. The prompt carries the plan name and the FULL plan
/// text — truncation is a host-UI concern (the js UI collapses long bodies
/// behind ctrl+o), never a protocol one. Approve accepts and starts
/// implementation; Revise asks for the (required) reason with a follow-up
/// input; Dismiss — or cancelling either modal — cancels the plan and stops
/// the turn.
pub(all) struct PlanApprovalSource {
  /// The composed UiPort, wired by the ui bridge extension at composition
  /// time. Empty only if composition never ran (asks fail closed).
  mut ui : &@posoco.UiPort?
}

///|
pub fn PlanApprovalSource::PlanApprovalSource() -> PlanApprovalSource {
  { ui: None, }
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
  let prompt = "Plan awaiting approval: " +
    request.name +
    "\n\n" +
    request.plan +
    "\n\nAccept, revise with feedback, or dismiss?"
  let req : @posoco.UiRequest = @posoco.UiRequest::Select(
    prompt~,
    options=[PLAN_OPTION_APPROVE, PLAN_OPTION_REVISE, PLAN_OPTION_DISMISS],
    default=Some(0),
  )
  let ui = match self.ui {
    Some(ui) => ui
    None => return @plan.PlanReviewDecision::Dismiss
  }
  let resp = ui.request(req) catch {
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
      let reason_resp = ui.request(reason_req) catch {
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

///|
pub extend BlockingApprovalSource with @permission.ApprovalSource::{ask}

///|
pub extend PlanApprovalSource with @plan.PlanReviewSource::{review}
