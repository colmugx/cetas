///|
/// Native Harness command dispatcher. Preserves the existing desktop
/// ConsoleRuntime method semantics without importing Proton or CEF.
fn harness_error(message : String) -> Json {
  Json::object(Map::from_array([("error", Json::string(message))]))
}

///|
fn harness_ok() -> Json {
  Json::object(Map::from_array([("ok", Json::boolean(true))]))
}

///|
fn harness_string(args : Json, name : String) -> String? {
  match args {
    Json::Object(fields) =>
      match fields.get(name) {
        Some(Json::String(value)) => Some(value)
        _ => None
      }
    _ => None
  }
}

///|
fn harness_required(args : Json, name : String) -> Result[String, String] {
  match harness_string(args, name) {
    Some(value) => Ok(value)
    None => Err("missing or invalid string field: " + name)
  }
}

///|
/// Console auth replies are JSON text (the bytes `login_outcome_json` and
/// friends produce); the harness envelope carries objects, so decode once here
/// and fall back to the raw text if a future reply is not JSON.
fn harness_console_json(text : String) -> Json {
  @json.parse(text) catch { _ => Json::string(text) }
}

///|
async fn harness_dispatch(
  runtime : @console.ConsoleRuntime,
  command : String,
  args : Json,
) -> Json {
  match command {
    "health" =>
      Json::object(Map::from_array([
        ("status", Json::string("ok")),
        ("host", Json::string("cetas-native")),
        ("protocol", Json::string("0.1")),
      ]))
    "versions" =>
      Json::object(Map::from_array([
        ("posoco", Json::string("0.22.0")),
        ("cetas", Json::string("0.2.0")),
        ("desktop", Json::string("0.1.0")),
      ]))
    "runtime_state" => runtime.runtime_json()
    "sessions" => runtime.sessions_json()
    "session_transcript" =>
      match harness_required(args, "id") {
        Ok(id) => runtime.transcript_json(id)
        Err(e) => harness_error(e)
      }
    "rewind_points" => runtime.rewind_points_json()
    "rewind_apply" =>
      match args {
        Json::Object(fields) =>
          match fields.get("message_index") {
            Some(Json::Number(index, ..)) =>
              runtime.rewind_active_session(index.to_int())
            _ => harness_error("rewind_apply requires message_index")
          }
        _ => harness_error("rewind_apply requires an object")
      }
    "session_rename" =>
      match (harness_required(args, "id"), harness_required(args, "name")) {
        (Ok(id), Ok(name)) =>
          match runtime.rename_session(id, name) {
            Ok(_) => harness_ok()
            Err(e) => harness_error(e)
          }
        _ => harness_error("session_rename needs id and name")
      }
    "login" =>
      match harness_required(args, "provider") {
        Ok(provider) => {
          // Provider sign-in parks on the GUI's ui_response, so it cannot be
          // awaited here: this loop is what delivers that answer. The console's
          // outcome JSON arrives as an auth.login frame once the flow settles.
          let auth_method = harness_string(args, "method").unwrap_or("")
          let session_id = runtime.active_session_id()
          runtime.spawn_background(async fn() {
            let result = runtime.login(provider, auth_method)
            runtime.emit_event(session_id, "", "auth.login", extra=[
              ("provider", Json::string(provider)),
              ("result", harness_console_json(result)),
            ])
          })
          Json::object(Map::from_array([
            ("status", Json::string("started")),
            ("provider", Json::string(provider)),
            ("session_id", Json::string(session_id)),
          ]))
        }
        Err(e) => harness_error(e)
      }
    "logout" =>
      match harness_required(args, "provider") {
        Ok(provider) => harness_console_json(runtime.logout(provider))
        Err(e) => harness_error(e)
      }
    // Read-only inventory: who can be signed in to, which methods, and whether
    // a credential record is stored. It never prompts, so awaiting it here is
    // safe.
    "providers" => runtime.providers_json()
    "extensions" => runtime.zoo_json()
    "file_search" =>
      runtime.file_suggestions_json(harness_string(args, "q").unwrap_or(""), 50)
    "skills" => runtime.skills_json()
    "trace" =>
      runtime.trace_json(harness_string(args, "session"), harness_string(args, "turn"))
    "workspaces" => runtime.workspaces_json()
    "switch_workspace" =>
      match harness_required(args, "cwd") {
        Ok(cwd) =>
          match runtime.switch_workspace(cwd) {
            Ok(_) => runtime.workspaces_json()
            Err(e) => harness_error(e)
          }
        Err(e) => harness_error(e)
      }
    "switch_session" =>
      match harness_string(args, "id") {
        Some(id) =>
          match runtime.switch_session(id) {
            Ok(session_id) =>
              Json::object(Map::from_array([("session_id", Json::string(session_id))]))
            Err(e) => harness_error(e)
          }
        None =>
          match runtime.new_session() {
            Ok(session_id) =>
              Json::object(Map::from_array([("session_id", Json::string(session_id))]))
            Err(e) => harness_error(e)
          }
      }
    "models" => runtime.model_slots_json(None)
    "switch_model" =>
      match harness_required(args, "slot_id") {
        Ok(slot) =>
          match runtime.switch_model(slot, harness_string(args, "session_id")) {
            Ok(_) => runtime.runtime_json()
            Err(e) => harness_error(e)
          }
        Err(e) => harness_error(e)
      }
    "select_effort" =>
      match harness_required(args, "effort") {
        Ok(effort) =>
          match runtime.select_effort(effort, harness_string(args, "session_id")) {
            Ok(_) => runtime.runtime_json()
            Err(e) => harness_error(e)
          }
        Err(e) => harness_error(e)
      }
    "set_permission" =>
      match harness_required(args, "mode") {
        Ok(mode) =>
          match runtime.set_permission(mode) {
            Ok(_) => runtime.runtime_json()
            Err(e) => harness_error(e)
          }
        Err(e) => harness_error(e)
      }
    "attach" => {
      runtime.emit_active_snapshot()
      runtime.republish_status()
      runtime.runtime_json()
    }
    "turn_start" =>
      match harness_required(args, "prompt") {
        Ok(prompt) =>
          if prompt.trim().is_empty() {
            harness_error("prompt must not be empty")
          } else {
            match runtime.start_turn(prompt, harness_string(args, "session_id")) {
              Ok(turn_id) =>
                Json::object(Map::from_array([("turn_id", Json::string(turn_id))]))
              Err(e) => harness_error(e)
            }
          }
        Err(e) => harness_error(e)
      }
    "turn_abort" => {
      runtime.abort_turn(harness_string(args, "session_id"))
      harness_ok()
    }
    "session_compact" => {
      // Compaction may invoke an LLM and a blocking UiPort prompt. It MUST
      // never suspend the only native command consumer: ui_response, abort
      // and shutdown must remain serviceable while compaction is running.
      runtime.spawn_background(async fn() {
        runtime.compact_active_session()
      })
      Json::object(Map::from_array([
        ("status", Json::string("started")),
      ]))
    }
    "status_refresh" => {
      let sid = harness_string(args, "session_id").unwrap_or(runtime.active_session_id())
      let quota = runtime.quota_json() catch { e => harness_error(e.to_string()) }
      runtime.emit_event(sid, "", "statusbar.quota", extra=[("payload", quota)])
      let all = runtime.quota_all_json() catch { e => harness_error(e.to_string()) }
      runtime.emit_event(sid, "", "statusbar.quota_all", extra=[("payload", all)])
      harness_ok()
    }
    "ui_response" =>
      match harness_required(args, "request_id") {
        Ok(request_id) => {
          runtime.resolve_ui(request_id, args.stringify())
          harness_ok()
        }
        Err(e) => harness_error(e)
      }
    other => harness_error("unknown harness command: " + other)
  }
}

///|
/// Native transport envelope: {id: positive integer, command: string,
/// args: object}. Results are {type:"harness.response", id, result}.
async fn harness_handle_frame(
  runtime : @console.ConsoleRuntime,
  raw : String,
) -> Unit {
  let request : Json = @json.parse(raw) catch {
    e => {
      emit(harness_reply(-1, harness_error("invalid JSON: " + e.to_string())))
      return
    }
  }
  match request {
    Json::Object(fields) => {
      let id = match fields.get("id") {
        Some(Json::Number(n, ..)) => n.to_int()
        _ => -1
      }
      let command = match fields.get("command") {
        Some(Json::String(s)) => s
        _ => ""
      }
      let args = fields.get("args").unwrap_or(Json::object(Map::from_array([])))
      if id < 0 || command.is_empty() {
        emit(harness_reply(id, harness_error("invalid request envelope")))
      } else {
        let result : Json = harness_dispatch(runtime, command, args) catch {
          e => harness_error(e.to_string())
        }
        emit(harness_reply(id, result))
      }
    }
    _ => emit(harness_reply(-1, harness_error("request must be a JSON object")))
  }
}

///|
fn harness_reply(id : Int, result : Json) -> String {
  Json::object(Map::from_array([
    ("type", Json::string("harness.response")),
    ("id", Json::number(id.to_double())),
    ("result", result),
  ])).stringify()
}
