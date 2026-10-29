///|
/// The Scrum Master's read-only view of one ticket. The facts are captured
/// when the consultation starts; the tool face exposes them by topic instead
/// of making the model parse the whole brief out of its prompt.
pub struct BoardCoordinationTools {
  task_id : String
  brief : String
}

///|
fn coordination_schema() -> Json {
  Json::object({
    "type": Json::string("object"),
    "properties": Json::object(Map([])),
    "additionalProperties": Json::boolean(false),
  })
}

///|
fn coordination_lines(brief : String, prefix : String) -> Array[String] {
  let out : Array[String] = []
  for line in brief.split("\n") {
    if line.has_prefix(prefix) {
      out.push(line.to_owned())
    }
  }
  out
}

///|
impl @posoco.ToolProvider for BoardCoordinationTools with fn list_tools(
  _self : BoardCoordinationTools,
) -> Array[@posoco.ToolDef] {
  let tool = fn(name : String, description : String) {
    @posoco.ToolDef(
      name=@posoco.ToolName::unchecked(name),
      description~,
      input_schema=coordination_schema(),
      owner=@posoco.OwnerId::unchecked("cetas_board"),
      policy=@posoco.ExecutionPolicy::Sequential,
      provenance=Some("cetas_board"),
    )
  }
  [
    tool(
      "board_coordination_brief", "Read the Scrum Master coordination brief for this ticket: stage, dependencies, other running work and open questions.",
    ),
    tool(
      "board_dependencies", "Read this ticket's dependencies and their current Board stages.",
    ),
    tool(
      "board_wip", "Read other tickets currently running work, including role.",
    ),
    tool(
      "board_questions", "Read the number of open questions across the Board.",
    ),
  ]
}

///|
fn BoardCoordinationTools::coordination_tool_content(
  self : BoardCoordinationTools,
  name : String,
) -> String? {
  let brief = self.brief
  match name {
    "board_coordination_brief" => Some(brief)
    "board_dependencies" => {
      let lines = coordination_lines(brief, "Dependency ")
      if lines.is_empty() {
        Some("Dependencies: none")
      } else {
        Some(lines.join("\n"))
      }
    }
    "board_wip" => {
      let lines = coordination_lines(brief, "Other running work:")
      Some(lines.join("\n"))
    }
    "board_questions" => {
      let lines = coordination_lines(brief, "Open questions:")
      Some(lines.join("\n"))
    }
    _ => None
  }
}

///|
impl @posoco.ToolProvider for BoardCoordinationTools with fn execute(
  self : BoardCoordinationTools,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let name = ctx.name.to_string()
  match self.coordination_tool_content(name) {
    Some(content) =>
      @posoco.ToolOutcome::Success(
        content~,
        structured=Some(
          Json::object({
            "task_id": Json::string(self.task_id),
            "tool": Json::string(name),
          }),
        ),
      )
    None =>
      @posoco.ToolOutcome::ToolReportedError(
        content="Unknown Board coordination tool: " + name,
        structured=None,
      )
  }
}

///|
impl @posoco.Extension for BoardCoordinationTools with fn extension_id(
  self : BoardCoordinationTools,
) -> String {
  let _ = self
  "board_coordination_sm"
}

///|
impl @posoco.Extension for BoardCoordinationTools with fn manifest(
  self : BoardCoordinationTools,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="board_coordination_sm", tools=[self])
}

///|
pub extend BoardCoordinationTools with @posoco.Extension::{
  extension_id,
  manifest,
}
