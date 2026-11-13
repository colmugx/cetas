///|
/// Plan review over the UiPort: the console host must present the full plan,
/// expose exactly the three verdicts, require a reason for a revision, and fail
/// closed (dismiss) whenever the answer cannot be read.

///|
/// Scripted UiPort: records every ask and replies from a queue, so a two-step
/// interaction (verdict, then revision reason) is exercisable.
priv struct ScriptedPlanUi {
  asked : Array[@posoco.UiRequest]
  pending : Array[@posoco.UiResponse]
  fail : Bool
}

///|
impl @posoco.UiPort for ScriptedPlanUi with fn ui_descriptor(
  _self : ScriptedPlanUi,
) -> @posoco.UiDescriptor {
  @posoco.UiDescriptor::empty()
}

///|
impl @posoco.UiPort for ScriptedPlanUi with fn render(
  _self : ScriptedPlanUi,
  _intent : @posoco.UiRender,
) -> Unit {
  ()
}

///|
impl @posoco.UiPort for ScriptedPlanUi with fn request(
  self : ScriptedPlanUi,
  req : @posoco.UiRequest,
) -> @posoco.UiResponse raise @posoco.UiError {
  self.asked.push(req)
  if self.fail {
    raise @posoco.UiError::IoFailure(detail="host rejected the ask")
  }
  if self.pending.length() == 0 {
    return @posoco.UiResponse::Cancelled
  }
  self.pending.remove(0)
}

///|
fn scripted_plan_ui(
  replies : Array[@posoco.UiResponse],
  fail~ : Bool = false,
) -> ScriptedPlanUi {
  { asked: [], pending: replies, fail, }
}

///|
fn plan_request() -> @plan.PlanReviewRequest {
  let sb = StringBuilder()
  for i in 0..<300 {
    sb.write_string("Step \{i}: investigate and verify the tricky part\n")
  }
  let plan = sb.to_string()
  { name: "auth refactor", plan, }
}

///|
async test "plan review accepts option 0 and shows the full plan" {
  let ui = scripted_plan_ui([@posoco.UiResponse::Selected(0)])
  let review = ConsolePlanReview::ConsolePlanReview(ui as &@posoco.UiPort)
  let request = plan_request()
  match review.review(request) {
    @plan.PlanReviewDecision::Accept => ()
    _ => fail("option 0 must accept the plan")
  }
  match ui.asked[0] {
    @posoco.UiRequest::Select(prompt~, options~, default~) => {
      assert_true(prompt.contains("Plan awaiting approval: auth refactor"))
      // The terminal renders the plan itself: a truncated prompt would hide
      // exactly the content the user is approving.
      assert_true(prompt.contains(request.plan))
      assert_eq(options.length(), 3)
      assert_eq(default, Some(0))
    }
    _ => fail("the plan review must be a select request")
  }
}

///|
async test "plan review sends the revision reason back to the model" {
  let ui = scripted_plan_ui([
    @posoco.UiResponse::Selected(1),
    @posoco.UiResponse::Text("split the migration out"),
  ])
  let review = ConsolePlanReview::ConsolePlanReview(ui as &@posoco.UiPort)
  match review.review({ name: "p", plan: "1. x", }) {
    @plan.PlanReviewDecision::Revise(feedback~) =>
      assert_eq(feedback, "split the migration out")
    _ => fail("option 1 plus a reason must revise")
  }
  assert_eq(ui.asked.length(), 2)
  assert_true(ui.asked[1] is @posoco.UiRequest::Input(..))
}

///|
async test "plan review dismisses instead of revising blind or guessing" {
  // A revision with no reason is a dismissal, not an empty feedback loop.
  let empty_reason = scripted_plan_ui([
    @posoco.UiResponse::Selected(1),
    @posoco.UiResponse::Text("   "),
  ])
  match
    ConsolePlanReview::ConsolePlanReview(empty_reason as &@posoco.UiPort).review({
        name: "p",
        plan: "1. x",
      },
    ) {
    @plan.PlanReviewDecision::Dismiss => ()
    _ => fail("an empty revision reason must dismiss")
  }
  // A cancelled verdict, an unreadable answer, and a broken UI all dismiss.
  for replies in [[@posoco.UiResponse::Cancelled], [@posoco.UiResponse::Yes]] {
    let ui = scripted_plan_ui(replies)
    match
      ConsolePlanReview::ConsolePlanReview(ui as &@posoco.UiPort).review({
        name: "p",
        plan: "1. x",
      }) {
      @plan.PlanReviewDecision::Dismiss => ()
      _ => fail("an unreadable verdict must dismiss")
    }
  }
  let broken = scripted_plan_ui([@posoco.UiResponse::Selected(0)], fail=true)
  match
    ConsolePlanReview::ConsolePlanReview(broken as &@posoco.UiPort).review({
      name: "p",
      plan: "1. x",
    }) {
    @plan.PlanReviewDecision::Dismiss => ()
    _ => fail("a failing UI must dismiss")
  }
}
