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
/// Session selectors accept the bounded replay schema's `session_id` and the
/// older `session_transcript` alias `id`, so both spellings address the same
/// journal.
fn harness_session_arg(args : Json) -> String? {
  match harness_string(args, "session_id") {
    Some(id) => Some(id)
    None => harness_string(args, "id")
  }
}

///|
fn harness_int(args : Json, name : String, fallback : Int32) -> Int32 {
  match args {
    Json::Object(fields) =>
      match fields.get(name) {
        Some(Json::Number(value, ..)) => value.to_int()
        _ => fallback
      }
    _ => fallback
  }
}

///|
/// Console auth replies are JSON text (the bytes `login_outcome_json` and
/// friends produce); the harness envelope carries objects, so decode once here
/// and fall back to the raw text if a future reply is not JSON.
fn harness_console_json(text : String) -> Json {
  @json.parse(text) catch {
    _ => Json::string(text)
  }
}

///|
async fn harness_dispatch(
  runtime : @console.ConsoleRuntime,
  auth_tasks : NativeAuthTasks,
  group : @async.TaskGroup[Unit],
  command : String,
  args : Json,
) -> Json {
  match command {
    // Cycle collection must run on the MoonBit owner thread at a safe point;
    // a foreign-thread call through the C symbol is not one. Diagnostic for
    // the per-turn retention investigation.
    "heap_collect_cycles" => {
      moonbit_collect_cycles()
      Json::object(Map::from_array([("ok", Json::boolean(true))]))
    }
    "health" =>
      Json::object(
        Map::from_array([
          ("status", Json::string("ok")),
          ("host", Json::string("cetas-go")),
          ("protocol", Json::string("0.1")),
        ]),
      )
    "versions" =>
      Json::object(
        Map::from_array([
          ("posoco", Json::string("0.22.0")),
          ("cetas", Json::string("0.2.0")),
          ("desktop", Json::string("0.1.0")),
        ]),
      )
    "runtime_state" => runtime.runtime_json()
    "commands" => runtime.commands_json()
    "invoke_command" =>
      match
        (harness_required(args, "session_id"), harness_required(args, "id")) {
        (Ok(session_id), Ok(id)) => {
          let arguments = match args {
            Json::Object(fields) =>
              fields
              .get("arguments")
              .unwrap_or(Json::object(Map::from_array([])))
            _ => Json::object(Map::from_array([]))
          }
          let request_id = harness_string(args, "request_id").unwrap_or("")
          // CommandPorts may request UI input or perform slow async work.
          // Do not block the sole dispatcher waiting for their completion.
          runtime.spawn_background(async fn() {
            let outcome = runtime.invoke_registered_command(
              session_id, id, arguments,
            ) catch {
              e =>
                Json::object({
                  "type": Json::string("failure"),
                  "reason": Json::string(e.to_string()),
                })
            }
            runtime.emit_event(session_id, "", "command.completed", extra=[
              ("command_id", Json::string(id)),
              ("request_id", Json::string(request_id)),
              ("outcome", outcome),
            ])
          })
          Json::object({
            "status": Json::string("started"),
            "request_id": Json::string(request_id),
          })
        }
        _ => harness_error("invoke_command requires session_id and id")
      }
    "sessions" => runtime.sessions_json()
    "session_catalog" =>
      runtime.session_catalog_json(
        harness_string(args, "scope").unwrap_or("current"),
        harness_string(args, "after").unwrap_or(""),
        harness_int(args, "limit", 100),
      )
    "session_transcript" =>
      match harness_required(args, "id") {
        Ok(id) => runtime.transcript_json(id)
        Err(e) => harness_error(e)
      }
    // Bounded native replay of the persisted JSONL journal: light index,
    // paged transcript items, and byte-range source chunks for giant bodies.
    // `session_transcript` above stays the whole-session oracle for the shared
    // and web hosts.
    "transcript_index" =>
      match harness_session_arg(args) {
        Some(session_id) =>
          runtime.transcript_index_json(
            session_id,
            first=harness_int(args, "first", -1),
            limit=harness_int(args, "limit", 0),
          )
        None => harness_error("transcript_index requires session_id")
      }
    "transcript_page" =>
      match harness_session_arg(args) {
        Some(session_id) =>
          runtime.transcript_page_json(
            session_id,
            harness_string(args, "revision").unwrap_or(""),
            harness_int(args, "first", 0),
            harness_int(args, "limit", 0),
            harness_int(args, "max_bytes", 0),
          )
        None => harness_error("transcript_page requires session_id")
      }
    "transcript_source" =>
      match harness_session_arg(args) {
        Some(session_id) =>
          match args {
            Json::Object(fields) =>
              match fields.get("index") {
                Some(Json::Number(index, ..)) =>
                  runtime.transcript_source_json(
                    session_id,
                    harness_string(args, "revision").unwrap_or(""),
                    index.to_int(),
                    field=harness_string(args, "field").unwrap_or(""),
                    offset=harness_int(args, "offset", 0),
                    length=harness_int(args, "length", 0),
                  )
                _ => harness_error("transcript_source requires index")
              }
            _ => harness_error("transcript_source requires an object")
          }
        None => harness_error("transcript_source requires session_id")
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
        Ok(provider) =>
          auth_tasks.start(
            runtime,
            group,
            provider,
            harness_string(args, "method").unwrap_or(""),
          )
        Err(e) => harness_error(e)
      }
    "login_cancel" =>
      match harness_required(args, "auth_id") {
        Ok(id) =>
          Json::object(
            Map::from_array([
              ("cancelled", Json::boolean(auth_tasks.cancel(runtime, id))),
              ("auth_id", Json::string(id)),
            ]),
          )
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
      runtime.trace_json(
        harness_string(args, "session"),
        harness_string(args, "turn"),
      )
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
    "switch_session" => {
      // Resuming a journal this process has not composed yet builds a whole
      // agent (recipe, tools, observers) — disk-heavy work that must never
      // hold the sole command consumer: ui_response, turn_abort and ping
      // stay serviceable while the switch composes. The reply is an
      // immediate ack; completion arrives as a `session.switched` event.
      let id = harness_string(args, "id")
      let cwd = harness_string(args, "cwd")
      let permission = harness_string(args, "permission")
      runtime.spawn_background(async fn() {
        let outcome : Result[String, String] = match id {
          Some(session_id) =>
            match cwd {
              Some(dir) =>
                runtime.resume_workspace_session(dir, session_id, permission)
              None => runtime.switch_session(session_id)
            }
          None => runtime.new_session()
        }
        match outcome {
          Ok(session_id) =>
            runtime.emit_host_event(session_id, "session.switched", extra=[
              ("fresh", Json::boolean(id is None)),
              ("snapshot", runtime.runtime_json()),
            ])
          Err(detail) =>
            runtime.emit_host_event(
              runtime.active_session_id(),
              "session.switch_failed",
              extra=[
                ("target", Json::string(id.unwrap_or(""))),
                ("detail", Json::string(detail)),
              ],
            )
        }
      })
      Json::object({
        "status": Json::string("switching"),
        "target": Json::string(id.unwrap_or("")),
      })
    }
    "session_prefetch" =>
      // Warm the handle cache for a row the picker is likely to choose.
      // Fire-and-forget on the background group: no reply payload beyond the
      // ack, and a prefetch that loses a race with a real switch is simply
      // redundant work whose handle lands in the cache.
      match harness_string(args, "session_id") {
        Some(session_id) => {
          runtime.spawn_background(async fn() {
            // The result is deliberate fire-and-forget: a failed prefetch
            // only means the row was not warmed; the real switch reports
            // its own failure through session.switch_failed.
            let _ : Result[String, String] = runtime.prefetch_session(
              session_id,
            )
          })
          Json::object({
            "status": Json::string("prefetching"),
            "session_id": Json::string(session_id),
          })
        }
        None => harness_error("session_prefetch requires session_id")
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
          match
            runtime.select_effort(effort, harness_string(args, "session_id")) {
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
        Ok(prompt) => {
          // Optional inline images: [{media_type, data(base64)}], the same
          // wire form the JS host's images_json carries.
          let images : Array[@posoco.Content] = []
          match args {
            Json::Object(fields) =>
              match fields.get("images") {
                Some(Json::Array(items)) =>
                  for item in items {
                    match item {
                      Json::Object(entry) =>
                        match (entry.get("media_type"), entry.get("data")) {
                          (
                            Some(Json::String(media_type)),
                            Some(Json::String(data)),
                          ) =>
                            images.push(
                              @posoco.Content::Image(media_type~, data~),
                            )
                          _ => ()
                        }
                      _ => ()
                    }
                  }
                _ => ()
              }
            _ => ()
          }
          if prompt.trim().is_empty() && images.is_empty() {
            harness_error("prompt must not be empty")
          } else {
            match
              runtime.start_turn(
                prompt,
                harness_string(args, "session_id"),
                images~,
              ) {
              Ok(turn_id) =>
                Json::object(
                  Map::from_array([("turn_id", Json::string(turn_id))]),
                )
              Err(e) => harness_error(e)
            }
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
      runtime.spawn_background(async fn() { runtime.compact_active_session() })
      Json::object(Map::from_array([("status", Json::string("started"))]))
    }
    "status_refresh" => {
      let sid = harness_string(args, "session_id").unwrap_or(
        runtime.active_session_id(),
      )
      let quota = runtime.quota_json() catch {
        e => harness_error(e.to_string())
      }
      runtime.emit_event(sid, "", "statusbar.quota", extra=[("payload", quota)])
      let all = runtime.quota_all_json() catch {
        e => harness_error(e.to_string())
      }
      runtime.emit_event(sid, "", "statusbar.quota_all", extra=[
        ("payload", all),
      ])
      harness_ok()
    }
    "pi_guest_install" =>
      match harness_required(args, "session_id") {
        Ok(id) => {
          let defs = match args {
            Json::Object(fields) =>
              fields.get("tools").unwrap_or(Json::array([]))
            _ => Json::array([])
          }
          match runtime.pi_guest_install(id, defs) {
            Ok(_) => harness_ok()
            Err(reason) => harness_error(reason)
          }
        }
        Err(reason) => harness_error(reason)
      }
    "pi_guest_result" =>
      match
        (
          harness_required(args, "session_id"),
          harness_required(args, "request_id"),
        ) {
        (Ok(id), Ok(request_id)) => {
          let result = match args {
            Json::Object(fields) => fields.get("result").unwrap_or(Json::null())
            _ => Json::null()
          }
          Json::object({
            "accepted": Json::boolean(
              runtime.pi_guest_result(id, request_id, result),
            ),
          })
        }
        _ => harness_error("pi_guest_result requires session_id and request_id")
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
  auth_tasks : NativeAuthTasks,
  replay_tasks : NativeReplayTasks,
  catalog_tasks : NativeReplayTasks,
  group : @async.TaskGroup[Unit],
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
      } else if native_replay_command(command) {
        replay_tasks.submit(runtime, auth_tasks, group, id, command, args)
      } else if native_catalog_command(command) {
        catalog_tasks.submit(runtime, auth_tasks, group, id, command, args)
      } else {
        // A resume retires the UI that queued the old session's reads; drop
        // them the moment the switch is asked for, before the switched-to
        // session's own first reads join the same FIFO. `new_session` has no
        // target id to keep, so it supersedes nothing.
        if command == "switch_session" {
          match harness_string(args, "id") {
            Some(target) =>
              if !target.is_empty() {
                replay_tasks.supersede(target)
              }
            None => ()
          }
        }
        let result : Json = harness_dispatch(
          runtime, auth_tasks, group, command, args,
        ) catch {
          e => harness_error(e.to_string())
        }
        emit(harness_reply(id, result))
      }
    }
    _ => emit(harness_reply(-1, harness_error("request must be a JSON object")))
  }
}

///|
fn harness_reply(id : Int32, result : Json) -> String {
  Json::object(
    Map::from_array([
      ("type", Json::string("harness.response")),
      ("id", Json::number(id.to_double())),
      ("result", result),
    ]),
  ).stringify()
}

///|
extern "C" fn moonbit_collect_cycles() -> Unit = "moonbit_collect_cycles"
