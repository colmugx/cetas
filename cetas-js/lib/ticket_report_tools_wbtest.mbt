///|
extend TicketReportTools with @posoco.ToolProvider::{list_tools, execute}

///|
struct RecordingReportEndpoint {
  progress : Array[(String, String)]
  mut report : Json?
}

///|
fn RecordingReportEndpoint::RecordingReportEndpoint() -> RecordingReportEndpoint {
  { progress: [], report: None, }
}

///|
impl TicketReportEndpoint for RecordingReportEndpoint with fn report_progress(
  self,
  kind,
  message,
) -> Unit {
  self.progress.push((kind, message))
}

///|
impl TicketReportEndpoint for RecordingReportEndpoint with fn submit_work_report(
  self,
  report,
) -> Result[Unit, String] {
  self.report = Some(report)
  Ok(())
}

///|
fn report_test_ctx(name : String, arguments : Json) -> @posoco.ToolCallContext {
  @posoco.ToolCallContext(
    effect_id=@kernel.EffectId::{ value: 1, },
    call_id=@posoco.CallId::unchecked("report-test"),
    name=@posoco.ToolName::unchecked(name),
    arguments~,
    register_cancel=fn(_ : &@posoco.ToolCancellable) { () },
  )
}

///|
test "ticket report tools expose progress and work report only" {
  let endpoint = RecordingReportEndpoint::RecordingReportEndpoint()
  let tools = TicketReportTools::TicketReportTools(endpoint~)
  let defs = tools.list_tools()
  assert_eq(defs.length(), 2)
  assert_eq(defs[0].name.to_string(), "report_progress")
  assert_eq(defs[1].name.to_string(), "submit_work_report")
}

///|
async test "ticket report tools record progress without a question" {
  let endpoint = RecordingReportEndpoint::RecordingReportEndpoint()
  let tools = TicketReportTools::TicketReportTools(endpoint~)
  let outcome = tools.execute(
    report_test_ctx(
      "report_progress",
      Json::object({
        "kind": Json::string("attention"),
        "message": Json::string(
          "Investigating one issue; overall work is on track.",
        ),
      }),
    ),
  )
  match outcome {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_eq(content, "Progress recorded.")
    _ => fail("report_progress must succeed")
  }
  assert_eq(endpoint.progress.length(), 1)
  assert_eq(endpoint.progress[0].0, "attention")
  assert_eq(
    endpoint.progress[0].1,
    "Investigating one issue; overall work is on track.",
  )
}

///|
async test "ticket report tools record the structured work report" {
  let endpoint = RecordingReportEndpoint::RecordingReportEndpoint()
  let tools = TicketReportTools::TicketReportTools(endpoint~)
  let report = Json::object({
    "outcome": Json::string("done"),
    "summary": Json::string("summary"),
    "changes": Json::array([Json::string("file.mbt")]),
    "verification": Json::array([]),
    "risks": Json::array([]),
    "notes": Json::array([]),
    "open_questions": Json::array([]),
    "artifacts": Json::array([]),
  })
  let outcome = tools.execute(report_test_ctx("submit_work_report", report))
  match outcome {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_eq(content, "Work report recorded.")
    _ => fail("submit_work_report must succeed")
  }
  assert_true(endpoint.report is Some(_))
  assert_eq(endpoint.report.unwrap().stringify().contains("\"summary\""), true)
}
