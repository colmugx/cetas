///|
/// Worker-facing reporting tools for a Board ticket child.

///|
let ticket_progress_kinds : Array[String] = [
  "normal", "milestone", "attention", "blocked",
]

///|
let ticket_progress_message_max : Int32 = 500

///|
let ticket_report_evidence_kinds : Array[String] = [
  "command", "test", "manual", "artifact",
]

///|
let ticket_report_evidence_results : Array[String] = [
  "passed", "failed", "not_run", "unknown",
]

///|
let ticket_report_artifact_kinds : Array[String] = [
  "file", "diff", "log", "screenshot", "url",
]

///|
/// Host side of the reporting tools; the endpoint carries the ticket binding.
pub(open) trait TicketReportEndpoint {
  fn report_progress(self : Self, kind : String, message : String) -> Unit
  fn submit_work_report(self : Self, report : Json) -> Result[Unit, String]
}

///|
/// The two non-Board tools a ticket child gets when the host provides a report
/// endpoint. Both are `Sequential`: each is a small host write that must not
/// interleave with other calls, and neither blocks on a human.
priv struct TicketReportTools {
  endpoint : &TicketReportEndpoint
}

///|
fn TicketReportTools::TicketReportTools(
  endpoint~ : &TicketReportEndpoint,
) -> TicketReportTools {
  { endpoint, }
}

///|
fn report_progress_schema() -> Json {
  Json::object({
    "type": Json::string("object"),
    "properties": Json::object({
      "kind": Json::object({
        "type": Json::string("string"),
        "enum": Json::array(ticket_progress_kinds.map(Json::string)),
        "description": Json::string(
          "normal (default), milestone, attention, or blocked. Use attention or blocked only for a real risk or blockage.",
        ),
      }),
      "message": Json::object({
        "type": Json::string("string"),
        "description": Json::string(
          "Short user-facing progress update; no question and no reply expected (non-empty, at most 500 characters)",
        ),
      }),
    }),
    "required": Json::array([Json::string("message")]),
  })
}

///|
fn report_string_array_schema(description : String) -> Json {
  Json::object({
    "type": Json::string("array"),
    "items": Json::object({ "type": Json::string("string") }),
    "description": Json::string(description),
  })
}

///|
fn work_report_schema() -> Json {
  Json::object({
    "type": Json::string("object"),
    "properties": Json::object({
      "outcome": Json::object({
        "type": Json::string("string"),
        "description": Json::string("What is now true, in one line"),
      }),
      "summary": Json::object({
        "type": Json::string("string"),
        "description": Json::string("What the work means and why it is enough"),
      }),
      "changes": report_string_array_schema(
        "What changed, one entry per change",
      ),
      "verification": Json::object({
        "type": Json::string("array"),
        "items": Json::object({
          "type": Json::string("object"),
          "properties": Json::object({
            "kind": Json::object({
              "type": Json::string("string"),
              "enum": Json::array(
                ticket_report_evidence_kinds.map(Json::string),
              ),
            }),
            "label": Json::object({ "type": Json::string("string") }),
            "result": Json::object({
              "type": Json::string("string"),
              "enum": Json::array(
                ticket_report_evidence_results.map(Json::string),
              ),
            }),
            "detail": Json::object({ "type": Json::string("string") }),
          }),
          "required": Json::array([
            Json::string("kind"),
            Json::string("label"),
            Json::string("result"),
            Json::string("detail"),
          ]),
        }),
        "description": Json::string("How each claim was verified"),
      }),
      "risks": report_string_array_schema("What could still bite"),
      "notes": report_string_array_schema("Context a reviewer needs"),
      "open_questions": report_string_array_schema(
        "Decisions still open for a human",
      ),
      "artifacts": Json::object({
        "type": Json::string("array"),
        "items": Json::object({
          "type": Json::string("object"),
          "properties": Json::object({
            "kind": Json::object({
              "type": Json::string("string"),
              "enum": Json::array(
                ticket_report_artifact_kinds.map(Json::string),
              ),
            }),
            "label": Json::object({ "type": Json::string("string") }),
            "uri_or_digest": Json::object({ "type": Json::string("string") }),
          }),
          "required": Json::array([
            Json::string("kind"),
            Json::string("label"),
            Json::string("uri_or_digest"),
          ]),
        }),
        "description": Json::string(
          "Referenced artifacts by URI or digest — never the body",
        ),
      }),
    }),
    "required": Json::array([
      Json::string("outcome"),
      Json::string("summary"),
      Json::string("changes"),
      Json::string("verification"),
      Json::string("risks"),
      Json::string("notes"),
      Json::string("open_questions"),
      Json::string("artifacts"),
    ]),
  })
}

///|
fn report_arguments(
  arguments : Json,
  tool : String,
) -> Result[Map[String, Json], String] {
  match arguments {
    Json::Object(fields) => Ok(fields)
    _ => Err(tool + ": arguments must be a JSON object")
  }
}

///|
fn parse_progress_arguments(
  arguments : Json,
) -> Result[(String, String), String] {
  let fields = match report_arguments(arguments, "report_progress") {
    Ok(fields) => fields
    Err(reason) => return Err(reason)
  }
  let message = match fields.get("message") {
    Some(Json::String(value)) => value.trim().to_owned()
    Some(_) => return Err("report_progress: 'message' must be a string")
    None => return Err("report_progress: 'message' is required")
  }
  if message.is_empty() {
    return Err("report_progress: 'message' must be a non-empty string")
  }
  if message.length() > ticket_progress_message_max {
    return Err(
      "report_progress: 'message' must be at most " +
      ticket_progress_message_max.to_string() +
      " characters",
    )
  }
  let kind = match fields.get("kind") {
    None | Some(Json::Null) => "normal"
    Some(Json::String(value)) => {
      let kind = value.trim().to_owned()
      if !ticket_progress_kinds.contains(kind) {
        return Err(
          "report_progress: 'kind' must be one of " +
          ticket_progress_kinds.join(", "),
        )
      }
      kind
    }
    Some(_) => return Err("report_progress: 'kind' must be a string")
  }
  Ok((kind, message))
}

///|
fn work_report_strings(
  fields : Map[String, Json],
  key : String,
) -> Result[Array[String], String] {
  let values = match fields.get(key) {
    None | Some(Json::Null) => return Ok([])
    Some(Json::Array(values)) => values
    Some(_) =>
      return Err(
        "submit_work_report: '" + key + "' must be an array of strings",
      )
  }
  let out : Array[String] = []
  for value in values {
    match value {
      Json::String(text) => out.push(text)
      _ =>
        return Err(
          "submit_work_report: every '" + key + "' entry must be a string",
        )
    }
  }
  Ok(out)
}

///|
fn work_report_string(
  fields : Map[String, Json],
  key : String,
  path : String,
) -> Result[String, String] {
  match fields.get(key) {
    Some(Json::String(value)) => Ok(value)
    Some(_) =>
      Err("submit_work_report: '" + path + "." + key + "' must be a string")
    None => Err("submit_work_report: '" + path + "." + key + "' is required")
  }
}

///|
fn work_report_evidence(value : Json) -> Result[Json, String] {
  let fields = match value {
    Json::Object(fields) => fields
    _ =>
      return Err(
        "submit_work_report: every 'verification' entry must be an object",
      )
  }
  let kind = match work_report_string(fields, "kind", "verification") {
    Ok(kind) => kind
    Err(reason) => return Err(reason)
  }
  if !ticket_report_evidence_kinds.contains(kind) {
    return Err(
      "submit_work_report: 'verification.kind' must be one of " +
      ticket_report_evidence_kinds.join(", "),
    )
  }
  let label = match work_report_string(fields, "label", "verification") {
    Ok(label) => label
    Err(reason) => return Err(reason)
  }
  if label.trim().is_empty() {
    return Err("submit_work_report: 'verification.label' must not be empty")
  }
  let result = match work_report_string(fields, "result", "verification") {
    Ok(result) => result
    Err(reason) => return Err(reason)
  }
  if !ticket_report_evidence_results.contains(result) {
    return Err(
      "submit_work_report: 'verification.result' must be one of " +
      ticket_report_evidence_results.join(", "),
    )
  }
  let detail = match fields.get("detail") {
    None | Some(Json::Null) => ""
    Some(Json::String(value)) => value
    Some(_) =>
      return Err("submit_work_report: 'verification.detail' must be a string")
  }
  Ok(
    Json::object({
      "kind": Json::string(kind),
      "label": Json::string(label),
      "result": Json::string(result),
      "detail": Json::string(detail),
    }),
  )
}

///|
fn work_report_artifact(value : Json) -> Result[Json, String] {
  let fields = match value {
    Json::Object(fields) => fields
    _ =>
      return Err(
        "submit_work_report: every 'artifacts' entry must be an object",
      )
  }
  let kind = match work_report_string(fields, "kind", "artifacts") {
    Ok(kind) => kind
    Err(reason) => return Err(reason)
  }
  if !ticket_report_artifact_kinds.contains(kind) {
    return Err(
      "submit_work_report: 'artifacts.kind' must be one of " +
      ticket_report_artifact_kinds.join(", "),
    )
  }
  let label = match work_report_string(fields, "label", "artifacts") {
    Ok(label) => label
    Err(reason) => return Err(reason)
  }
  if label.trim().is_empty() {
    return Err("submit_work_report: 'artifacts.label' must not be empty")
  }
  let uri_or_digest = match
    work_report_string(fields, "uri_or_digest", "artifacts") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  if uri_or_digest.trim().is_empty() {
    return Err(
      "submit_work_report: 'artifacts.uri_or_digest' must not be empty",
    )
  }
  Ok(
    Json::object({
      "kind": Json::string(kind),
      "label": Json::string(label),
      "uri_or_digest": Json::string(uri_or_digest),
    }),
  )
}

///|
fn work_report_entries(
  fields : Map[String, Json],
  key : String,
  entry : (Json) -> Result[Json, String],
) -> Result[Array[Json], String] {
  let values = match fields.get(key) {
    None | Some(Json::Null) => return Ok([])
    Some(Json::Array(values)) => values
    Some(_) => return Err("submit_work_report: '" + key + "' must be an array")
  }
  let out : Array[Json] = []
  for value in values {
    match entry(value) {
      Ok(item) => out.push(item)
      Err(reason) => return Err(reason)
    }
  }
  Ok(out)
}

///|
fn parse_work_report_arguments(arguments : Json) -> Result[Json, String] {
  let fields = match report_arguments(arguments, "submit_work_report") {
    Ok(fields) => fields
    Err(reason) => return Err(reason)
  }
  let outcome = match fields.get("outcome") {
    Some(Json::String(value)) => value.trim().to_owned()
    Some(_) => return Err("submit_work_report: 'outcome' must be a string")
    None => return Err("submit_work_report: 'outcome' is required")
  }
  if outcome.is_empty() {
    return Err("submit_work_report: 'outcome' must not be empty")
  }
  let summary = match fields.get("summary") {
    Some(Json::String(value)) => value.trim().to_owned()
    Some(_) => return Err("submit_work_report: 'summary' must be a string")
    None => return Err("submit_work_report: 'summary' is required")
  }
  if summary.is_empty() {
    return Err("submit_work_report: 'summary' must not be empty")
  }
  let changes = match work_report_strings(fields, "changes") {
    Ok(values) => values
    Err(reason) => return Err(reason)
  }
  let verification = match
    work_report_entries(fields, "verification", work_report_evidence) {
    Ok(values) => values
    Err(reason) => return Err(reason)
  }
  let risks = match work_report_strings(fields, "risks") {
    Ok(values) => values
    Err(reason) => return Err(reason)
  }
  let notes = match work_report_strings(fields, "notes") {
    Ok(values) => values
    Err(reason) => return Err(reason)
  }
  let open_questions = match work_report_strings(fields, "open_questions") {
    Ok(values) => values
    Err(reason) => return Err(reason)
  }
  let artifacts = match
    work_report_entries(fields, "artifacts", work_report_artifact) {
    Ok(values) => values
    Err(reason) => return Err(reason)
  }
  Ok(
    Json::object({
      "outcome": Json::string(outcome),
      "summary": Json::string(summary),
      "changes": Json::array(changes.map(Json::string)),
      "verification": Json::array(verification),
      "risks": Json::array(risks.map(Json::string)),
      "notes": Json::array(notes.map(Json::string)),
      "open_questions": Json::array(open_questions.map(Json::string)),
      "artifacts": Json::array(artifacts),
    }),
  )
}

///|
impl @posoco.ToolProvider for TicketReportTools with fn list_tools(
  _self : TicketReportTools,
) -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("report_progress"),
      description: "Post a short, non-blocking progress update for this ticket. It appears beside the run and expects no reply: call it at the start, after each significant milestone, when investigating a problem, and before your final answer. Use kind \"attention\" or \"blocked\" only for a real risk or blockage. Questions still go through ask_question_child.",
      input_schema: report_progress_schema(),
      owner: @posoco.OwnerId::unchecked("cetas_ticket"),
      policy: @posoco.ExecutionPolicy::Sequential,
      provenance: Some("cetas_ticket"),
    },
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("submit_work_report"),
      description: "Submit the curated final work report for this ticket: outcome, what changed, verification evidence, risks, notes, open questions and artifacts. Call it before your final answer once evidence exists. The host records it as this attempt's review report; an invalid report fails visibly.",
      input_schema: work_report_schema(),
      owner: @posoco.OwnerId::unchecked("cetas_ticket"),
      policy: @posoco.ExecutionPolicy::Sequential,
      provenance: Some("cetas_ticket"),
    },
  ]
}

///|
impl @posoco.ToolProvider for TicketReportTools with fn execute(
  self : TicketReportTools,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let name = ctx.name.to_string()
  if name == "report_progress" {
    let (kind, message) = match parse_progress_arguments(ctx.arguments) {
      Ok(parsed) => parsed
      Err(reason) =>
        return @posoco.ToolOutcome::ToolReportedError(
          content=reason,
          structured=None,
        )
    }
    self.endpoint.report_progress(kind, message)
    return @posoco.ToolOutcome::Success(
      content="Progress recorded.",
      structured=Some(
        Json::object({
          "recorded": Json::boolean(true),
          "kind": Json::string(kind),
          "message": Json::string(message),
        }),
      ),
    )
  }
  if name == "submit_work_report" {
    let report = match parse_work_report_arguments(ctx.arguments) {
      Ok(report) => report
      Err(reason) =>
        return @posoco.ToolOutcome::ToolReportedError(
          content=reason,
          structured=None,
        )
    }
    match self.endpoint.submit_work_report(report) {
      Ok(_) => ()
      Err(reason) =>
        return @posoco.ToolOutcome::ToolReportedError(
          content="submit_work_report: " + reason,
          structured=None,
        )
    }
    return @posoco.ToolOutcome::Success(
      content="Work report recorded.",
      structured=Some(Json::object({ "recorded": Json::boolean(true) })),
    )
  }
  raise @posoco.RuntimeError::UnknownTool(
    "cetas_ticket: unknown tool '" + name + "'",
  )
}

///|
impl @posoco.Extension for TicketReportTools with fn extension_id(
  _self : TicketReportTools,
) -> String {
  "cetas_ticket_report"
}

///|
impl @posoco.Extension for TicketReportTools with fn manifest(
  self : TicketReportTools,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="cetas_ticket_report", tools=[self])
}
