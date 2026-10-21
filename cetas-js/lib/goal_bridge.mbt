///|
/// Cetas host-owned evidence source: user explicitly approves the actual
/// completion claim. Without approval the goal remains unverified; the
/// model cannot self-certify.
pub struct CetasGoalApprovalVerifier {
  ui : JsUiPort
}

///|
pub fn CetasGoalApprovalVerifier::CetasGoalApprovalVerifier(
  ui : JsUiPort,
) -> CetasGoalApprovalVerifier {
  { ui, }
}

///|
pub extend CetasGoalApprovalVerifier with @goal.GoalVerifier::{verify}

///|
pub impl @goal.GoalVerifier for CetasGoalApprovalVerifier with fn verify(
  self : CetasGoalApprovalVerifier,
  request : @goal.GoalVerificationRequest,
) -> @goal.GoalAssessment {
  let prompt = "Goal completion review\nGoal: " +
    request.goal +
    "\nClaim: " +
    request.claim +
    "\nOnly approve if you independently checked the result. Approve completion?"
  let response = self.ui.request(@port.UiRequest::Confirm(prompt~)) catch {
    _ => @port.UiResponse::Cancelled
  }
  match response {
    @port.UiResponse::Yes => {
      let names = if request.criteria.is_empty() {
        ["goal"]
      } else {
        request.criteria
      }
      @goal.GoalAssessment::Verified(
        names.map(fn(criterion) {
          @goal.GoalEvidence::{
            criterion,
            source: "cetas.human_approval",
            reference: request.session_id,
          }
        }),
      )
    }
    @port.UiResponse::No =>
      @goal.GoalAssessment::Rejected("human reviewer rejected completion")
    _ =>
      @goal.GoalAssessment::Inconclusive(
        "human completion review was cancelled or unavailable",
      )
  }
}

///|
/// Deliberately separate control plane from normal agent prompts. A goal
/// executes on the existing Agent, so its tool permissions and ModelPort are
/// exactly the same as ordinary turns. A missing JEV is not a dependency.
pub fn cetas_js_goal_start(
  handle : CetasJsAgent,
  condition : String,
  session_id : String,
  signal : @js_async.AbortSignal,
) -> @js_async.Promise[String] {
  @js_async.Promise::from_async(abort_signal=signal) <| () => {
    match handle.goal.prepare_goal(condition) {
      Err(reason) =>
        Json::object({
          "type": Json::string("failure"),
          "reason": Json::string(reason),
        }).stringify()
      Ok(_) => {
        handle.plan.set_session_name(session_id)
        let result = handle.goal.execute(handle.agent, session_id)
        goal_result_json(result)
      }
    }
  }
}

///|
pub fn cetas_js_goal_resume(
  handle : CetasJsAgent,
  session_id : String,
  signal : @js_async.AbortSignal,
) -> @js_async.Promise[String] {
  @js_async.Promise::from_async(abort_signal=signal) <| () => {
    handle.goal.resume_goal()
    goal_result_json(handle.goal.execute(handle.agent, session_id))
  }
}

///|
pub fn cetas_js_goal_pause(handle : CetasJsAgent) -> Unit {
  handle.goal.pause()
}

///|
pub fn cetas_js_goal_status(handle : CetasJsAgent) -> String {
  Json::object({
    "status": Json::string(handle.goal.status().to_string()),
    "plan": Json::string(@goal.GoalPlan::render(handle.goal.plan())),
  }).stringify()
}

///|
fn goal_result_json(result : @goal.GoalResult) -> String {
  Json::object({
    "type": Json::string("success"),
    "feedback": Json::string("Goal: " + result.final_status.to_string()),
    "structured": Json::object({
      "status": Json::string(result.final_status.to_string()),
      "turns": Json::number(result.turns_completed.to_double()),
      "tokens": Json::number(result.total_usage.total_tokens.to_double()),
      "plan": Json::string(@goal.GoalPlan::render(result.final_plan)),
      "assessment": Json::string("\{result.assessment.to_repr()}"),
    }),
  }).stringify()
}

///|
/// Export a settled-run checkpoint. The JS host persists this JSON adjacent
/// to its existing transcript store; the runner never owns filesystem IO.
pub fn cetas_js_goal_checkpoint(handle : CetasJsAgent) -> String {
  match handle.goal.checkpoint() {
    Ok(snapshot) =>
      Json::object({ "ok": Json::boolean(true), "snapshot": snapshot }).stringify()
    Err(reason) =>
      Json::object({
        "ok": Json::boolean(false),
        "reason": Json::string(reason),
      }).stringify()
  }
}

///|
/// Rehydrate a goal in a newly composed process. The host supplies the
/// checkpoint from the matching durable session; we do not infer any
/// authority or expand the goal contract during restore.
pub fn cetas_js_goal_restore(
  handle : CetasJsAgent,
  snapshot_json : String,
) -> String {
  let snapshot = @json.parse(snapshot_json) catch {
    _ =>
      return Json::object({
        "ok": Json::boolean(false),
        "reason": Json::string("invalid goal checkpoint JSON"),
      }).stringify()
  }
  let condition = match snapshot {
    Json::Object(fields) =>
      match fields.get("goal") {
        Some(Json::String(v)) => v
        _ => ""
      }
    _ => ""
  }
  let prepared = handle.goal.prepare_goal(condition)
  match prepared {
    Err(reason) =>
      Json::object({
        "ok": Json::boolean(false),
        "reason": Json::string(reason),
      }).stringify()
    Ok(_) =>
      match handle.goal.restore_checkpoint(snapshot) {
        Ok(_) => Json::object({ "ok": Json::boolean(true) }).stringify()
        Err(reason) =>
          Json::object({
            "ok": Json::boolean(false),
            "reason": Json::string(reason),
          }).stringify()
      }
  }
}
