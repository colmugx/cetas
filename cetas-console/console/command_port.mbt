///|
/// The native command catalog is the composed Agent's real CommandPort
/// registry. Keep this wire schema aligned with cetas-js command descriptors:
/// the terminal never invents extension commands or their arguments.
fn console_command_def_json(def : @posoco.CommandDef) -> Json {
  let params : Array[Json] = []
  for param in def.params {
    let fields : Array[(String, Json)] = [
      ("name", Json::string(param.name)),
      ("label", Json::string(param.label)),
      ("description", Json::string(param.description)),
      (
        "ptype",
        Json::string(
          match param.ptype {
            Str => "str"
            Int => "int"
            Bool => "bool"
            Strs => "strs"
          },
        ),
      ),
      ("required", Json::boolean(param.required)),
      ("positional", Json::boolean(param.positional)),
    ]
    match param.default {
      Some(value) => fields.push(("default", value))
      None => ()
    }
    match param.choices {
      Some(choices) => {
        let items : Array[Json] = []
        for choice in choices {
          items.push(Json::string(choice))
        }
        fields.push(("choices", Json::array(items)))
      }
      None => ()
    }
    params.push(Json::object(Map::from_array(fields)))
  }
  let aliases : Array[Json] = []
  for alternate in def.aliases {
    aliases.push(Json::string(alternate))
  }
  let fields : Array[(String, Json)] = [
    ("id", Json::string(def.id)),
    ("label", Json::string(def.label)),
    ("description", Json::string(def.description)),
    ("category", Json::string(def.category)),
    (
      "ctype",
      Json::string(
        match def.ctype {
          Action => "action"
          Toggle => "toggle"
          Select => "select"
          Input => "input"
          MultiStep => "multi_step"
        },
      ),
    ),
    ("params", Json::array(params)),
    ("aliases", Json::array(aliases)),
    ("visible", Json::boolean(def.visible)),
  ]
  match def.shortcut {
    Some(value) => fields.push(("shortcut", Json::string(value)))
    None => ()
  }
  Json::object(Map::from_array(fields))
}

///|
fn console_command_outcome_json(outcome : @posoco.CommandOutcome) -> Json {
  match outcome {
    Success(feedback~, structured~, ui_hint~) => {
      let fields : Array[(String, Json)] = [
        ("type", Json::string("success")),
        ("feedback", Json::string(feedback)),
      ]
      match structured {
        Some(value) => fields.push(("structured", value))
        None => ()
      }
      match ui_hint {
        Some(hint) =>
          fields.push(
            (
              "ui_hint",
              Json::string(
                match hint {
                  RefreshModelList => "refresh_model_list"
                  RefreshSettings => "refresh_settings"
                  ClosePanel => "close_panel"
                  Toast => "toast"
                  None => "none"
                },
              ),
            ),
          )
        None => ()
      }
      Json::object(Map::from_array(fields))
    }
    Failure(reason~) =>
      Json::object({
        "type": Json::string("failure"),
        "reason": Json::string(reason),
      })
    NeedsInput(prompt~) =>
      Json::object({
        "type": Json::string("needs_input"),
        "prompt": Json::string(prompt),
      })
  }
}

///|
/// One snapshot is associated with the active session. An asynchronous
/// response for a previous session cannot replace the new command palette.
pub fn ConsoleRuntime::commands_json(self : ConsoleRuntime) -> Json {
  let session_id = self.active_session_id()
  let defs : Array[Json] = []
  for port in self.active().active().agent.commands() {
    for definition in port.commands() {
      defs.push(console_command_def_json(definition))
    }
  }
  Json::object({
    "session_id": Json::string(session_id),
    "commands": Json::array(defs),
  })
}

///|
/// Invoke exactly the command id supplied by the live catalog. The caller
/// must explicitly submit a command; aliases are normalized by the Go shell.
/// Reject sessions changed during asynchronous scheduling before invoking.
pub async fn ConsoleRuntime::invoke_registered_command(
  self : ConsoleRuntime,
  session_id : String,
  id : String,
  args : Json,
) -> Json {
  if self.active_session_id() != session_id {
    return console_command_outcome_json(
      @posoco.CommandOutcome::Failure(reason="session changed before command invocation"),
    )
  }
  let ports = self.active().active().agent.commands()
  for port in ports {
    if port.commands().iter().any(fn(def) { def.id == id }) {
      return console_command_outcome_json(port.invoke(id, args))
    }
  }
  console_command_outcome_json(
    @posoco.CommandOutcome::Failure(reason="command not found: " + id),
  )
}
