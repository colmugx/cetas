///|
/// Plan-mode review over the composed UiPort.
///
/// `PlanReviewSource` only carries the verdict; the UX is host product content.
/// Both console hosts already render `select` and `input` requests (the same
/// modals that answer a permission ask), so approving a plan needs no new
/// surface: three options, then the revision reason when the plan is sent back.

///|
pub(all) struct ConsolePlanReview {
  ui : &@posoco.UiPort
}

///|
pub fn ConsolePlanReview::ConsolePlanReview(
  ui : &@posoco.UiPort,
) -> ConsolePlanReview {
  { ui, }
}

///|
const PLAN_OPTION_APPROVE = "Approve — accept the plan and implement it"

///|
const PLAN_OPTION_REVISE = "Revise — send the plan back with feedback"

///|
const PLAN_OPTION_DISMISS = "Dismiss — cancel the plan and stop"

///|
/// Every failure mode dismisses rather than revising blind: a cancelled or
/// unreadable answer must not push an empty reason at the model.
pub impl @plan.PlanReviewSource for ConsolePlanReview with fn review(
  self,
  request : @plan.PlanReviewRequest,
) -> @plan.PlanReviewDecision {
  let prompt = "Plan awaiting approval: " +
    request.name +
    "\n\n" +
    request.plan +
    "\n\nAccept, revise with feedback, or dismiss?"
  let ask : @posoco.UiRequest = @posoco.UiRequest::Select(
    prompt~,
    options=[PLAN_OPTION_APPROVE, PLAN_OPTION_REVISE, PLAN_OPTION_DISMISS],
    default=Some(0),
  )
  let answer = self.ui.request(ask) catch {
    _ => return @plan.PlanReviewDecision::Dismiss
  }
  match answer {
    @posoco.UiResponse::Selected(0) => @plan.PlanReviewDecision::Accept
    @posoco.UiResponse::Selected(1) => {
      let reason_request : @posoco.UiRequest = @posoco.UiRequest::Input(
        prompt="Why is the plan sent back? (required feedback for the model)",
        default=Some(""),
      )
      let reason = self.ui.request(reason_request) catch {
        _ => return @plan.PlanReviewDecision::Dismiss
      }
      match reason {
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
pub extend ConsolePlanReview with @plan.PlanReviewSource::{review}

///|
/// Build the session's plan-mode extension. It must be constructed after the
/// permission gate subscribes (hence `events_exts`): its enter/exit tools are
/// reported as typed exemptions so their governance stays the plan review, not
/// a second tool-permission ask.
fn compose_plan_mode(
  events : @posoco.EventSystem,
  review : ConsolePlanReview,
  fs : &@workspace.WorkspaceFs,
  cwd : String,
) -> @plan.PlanMode {
  @plan.PlanMode(
    config={
      // Model entry is on: the model itself can propose planning. Exit stays
      // `exit_plan_mode` behind the review above.
      ..@plan.PlanModeConfig::default(),
      allow_model_entry: true,
    },
    review=Some(review as &@plan.PlanReviewSource),
    events=@cetas_core.mint_events_publisher(events, owner="posoco_ext_plan"),
    // Plan narrative and named plans persist under .cetas/plan/ through the
    // workspace boundary; the anchor lets the write gate prove a target is
    // inside the workspace.
    fs=Some(fs),
    anchor=Some(@devkit.WorkspaceAnchor::WorkspaceAnchor(cwd)),
  )
}
