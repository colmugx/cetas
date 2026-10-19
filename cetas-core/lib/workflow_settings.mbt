///|
/// Host-independent product settings; parsing does not grant workflow authority.
pub struct CetasWorkflowSettings {
  enabled : Bool
  max_executions : Int32
  max_elapsed_ms : Int32
  execution_timeout_ms : Int32
  max_concurrency : Int32
  max_expansions : Int32
  max_generated_tasks : Int32
  max_depth : Int32
  continue_on_confirmed_failure : Bool
}

///|
pub fn workflow_settings_from_json(
  text : String,
) -> CetasWorkflowSettings raise @posoco.CompositionError {
  let settings = parse_settings_json(text, manifest_id="cetas.workflow")
  let fields = match settings {
    Json::Object(fields) => fields
    _ => raise workflow_settings_error(".cetas/settings.json must be an object")
  }
  let fields = match fields.get("workflow") {
    None => Map([])
    Some(Json::Object(fields)) => fields
    _ => raise workflow_settings_error("settings.workflow must be an object")
  }
  for key, _ in fields {
    match key {
      "enabled"
      | "max_executions"
      | "max_elapsed_ms"
      | "execution_timeout_ms"
      | "max_concurrency"
      | "max_expansions"
      | "max_generated_tasks"
      | "max_depth"
      | "continue_on_confirmed_failure" => ()
      _ =>
        raise workflow_settings_error("settings.workflow unknown key: " + key)
    }
  }
  let max_elapsed_ms = workflow_budget(
    fields,
    "max_elapsed_ms",
    default=600000,
    maximum=86400000,
  )
  let execution_timeout_ms = workflow_budget(
    fields,
    "execution_timeout_ms",
    default=60000,
    maximum=86400000,
  )
  if execution_timeout_ms > max_elapsed_ms {
    raise workflow_settings_error(
      "execution_timeout_ms must not exceed max_elapsed_ms",
    )
  }
  {
    enabled: workflow_flag(fields, "enabled"),
    max_elapsed_ms,
    execution_timeout_ms,
    max_executions: workflow_budget(
      fields,
      "max_executions",
      default=8,
      maximum=1000,
    ),
    max_concurrency: workflow_budget(
      fields,
      "max_concurrency",
      default=2,
      maximum=8,
    ),
    max_expansions: workflow_budget(
      fields,
      "max_expansions",
      default=2,
      maximum=16,
    ),
    max_generated_tasks: workflow_budget(
      fields,
      "max_generated_tasks",
      default=20,
      maximum=200,
    ),
    max_depth: workflow_budget(
      fields,
      "max_depth",
      default=16,
      minimum=2,
      maximum=16,
    ),
    continue_on_confirmed_failure: workflow_flag(
      fields, "continue_on_confirmed_failure",
    ),
  }
}

///|
fn workflow_settings_error(detail : String) -> @posoco.CompositionError {
  @posoco.CompositionError::ManifestSchemaError(
    manifest_id="cetas.workflow",
    detail~,
  )
}

///|
fn workflow_flag(
  fields : Map[String, Json],
  key : String,
) -> Bool raise @posoco.CompositionError {
  match fields.get(key) {
    None | Some(Json::False) => false
    Some(Json::True) => true
    _ =>
      raise workflow_settings_error(
        "settings.workflow." + key + " must be a boolean",
      )
  }
}

///|
fn workflow_budget(
  fields : Map[String, Json],
  key : String,
  default~ : Int32,
  minimum~ : Int32 = 1,
  maximum~ : Int32,
) -> Int32 raise @posoco.CompositionError {
  match fields.get(key) {
    None => default
    Some(Json::Number(value, ..)) => {
      if value != value.floor() {
        raise workflow_settings_error(
          "settings.workflow." + key + " must be a whole number",
        )
      }
      if value < minimum.to_double() || value > maximum.to_double() {
        raise workflow_settings_error(
          "settings.workflow." +
          key +
          " must be between " +
          minimum.to_string() +
          " and " +
          maximum.to_string(),
        )
      }
      value.to_int()
    }
    _ =>
      raise workflow_settings_error(
        "settings.workflow." + key + " must be a number",
      )
  }
}
