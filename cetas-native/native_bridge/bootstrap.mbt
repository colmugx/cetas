///|
/// Empty-home setup tasks live outside ConsoleRuntime because no Agent exists
/// until an authenticated provider has produced an offline model catalog.
priv struct NativeBootstrapTasks {
  mut next_id : Int32
  pending : Map[String, @async.Task[Unit]]
  cancelled : Map[String, Bool]
}

///|
fn NativeBootstrapTasks::new() -> NativeBootstrapTasks {
  { next_id: 1, pending: Map([]), cancelled: Map([]), }
}

///|
fn NativeBootstrapTasks::start(
  self : NativeBootstrapTasks,
  setup : @console.ConsoleBootstrap,
  boot : Ref[Result[@console.ConsoleRuntime, String]],
  config : @console.ConsoleConfig,
  cwd : String,
  group : @async.TaskGroup[Unit],
  provider : String,
  method : String,
) -> Json {
  for _, _ in self.pending {
    return harness_error("another provider login is still active")
  }
  let id = "setup-auth-" + self.next_id.to_string()
  self.next_id += 1
  let task = group.spawn(
    () => {
      defer {
        self.pending.remove(id)
        self.cancelled.remove(id)
      }
      let outcome = harness_console_json(setup.login(provider, method))
      if self.cancelled.contains(id) {
        return
      }
      setup.emit_event("auth.login", extra=[
        ("auth_id", Json::string(id)),
        ("provider", Json::string(provider)),
        ("result", outcome),
      ])
      let succeeded = match outcome {
        Json::Object(fields) =>
          fields.get("type") is Some(Json::String("success"))
        _ => false
      }
      if succeeded {
        let composed : Result[@console.ConsoleRuntime, String] = Ok(
          @console.compose_console_runtime(config, cwd, group),
        ) catch {
          err => Err(err.to_string())
        }
        if self.cancelled.contains(id) {
          return
        }
        match composed {
          Ok(runtime) => {
            runtime.attach_sink(fn(frame : String) { emit(frame) })
            boot.val = Ok(runtime)
            emit(
              Json::object({
                "type": Json::string("infra.ready"),
                "snapshot": runtime.runtime_json(),
              }).stringify(),
            )
          }
          Err(_) =>
            setup.emit_event("infra.setup_failed", extra=[
              (
                "detail",
                Json::string(
                  "Authentication saved, but no usable model catalog is available. Configure the provider's model or choose another provider.",
                ),
              ),
            ])
        }
      }
    },
    allow_failure=true,
  )
  self.pending[id] = task
  Json::object({
    "status": Json::string("started"),
    "auth_id": Json::string(id),
    "provider": Json::string(provider),
  })
}

///|
fn NativeBootstrapTasks::cancel(
  self : NativeBootstrapTasks,
  setup : @console.ConsoleBootstrap,
  id : String,
  group : @async.TaskGroup[Unit],
) -> Bool {
  match self.pending.get(id) {
    Some(task) => {
      if self.cancelled.contains(id) {
        return false
      }
      self.cancelled[id] = true
      task.cancel()
      group.spawn(
        () => {
          let _ = task.wait() catch { _ => () }
          self.pending.remove(id)
          self.cancelled.remove(id)
        },
        allow_failure=true,
      ) |> ignore
      setup.emit_event("auth.cancelled", extra=[
        ("auth_id", Json::string(id)),
      ])
      true
    }
    None => false
  }
}

///|
fn NativeBootstrapTasks::cancel_all(self : NativeBootstrapTasks) -> Unit {
  for id, task in self.pending {
    self.cancelled[id] = true
    task.cancel()
  }
}

///|
/// The restricted pre-Agent command surface never accepts turns, tool calls,
/// permissions or session rewinds. Only explicit authentication and its
/// correlated UI replies can be dispatched before successful composition.
async fn bootstrap_dispatch(
  setup : @console.ConsoleBootstrap,
  tasks : NativeBootstrapTasks,
  boot : Ref[Result[@console.ConsoleRuntime, String]],
  config : @console.ConsoleConfig,
  cwd : String,
  group : @async.TaskGroup[Unit],
  command : String,
  args : Json,
) -> Json {
  match command {
    "runtime_state" =>
      Json::object({
        "status": Json::string("needs_setup"),
        "session_id": Json::string(""),
      })
    "providers" => setup.providers_json()
    "login" =>
      match harness_required(args, "provider") {
        Ok(provider) =>
          tasks.start(
            setup,
            boot,
            config,
            cwd,
            group,
            provider,
            harness_string(args, "method").unwrap_or(""),
          )
        Err(error) => harness_error(error)
      }
    "login_cancel" =>
      match harness_required(args, "auth_id") {
        Ok(id) =>
          Json::object({
            "cancelled": Json::boolean(tasks.cancel(setup, id, group)),
            "auth_id": Json::string(id),
          })
        Err(error) => harness_error(error)
      }
    "ui_response" =>
      match harness_required(args, "request_id") {
        Ok(id) => {
          setup.resolve_ui(id, args.stringify())
          harness_ok()
        }
        Err(error) => harness_error(error)
      }
    other =>
      harness_error(
        "complete provider setup before using " + other,
      )
  }
}

///|
async fn bootstrap_handle_frame(
  setup : @console.ConsoleBootstrap,
  tasks : NativeBootstrapTasks,
  boot : Ref[Result[@console.ConsoleRuntime, String]],
  config : @console.ConsoleConfig,
  cwd : String,
  group : @async.TaskGroup[Unit],
  raw : String,
) -> Unit {
  let parsed : Json = @json.parse(raw) catch {
    err => {
      emit(harness_reply(-1, harness_error("invalid JSON: " + err.to_string())))
      return
    }
  }
  match parsed {
    Json::Object(fields) => {
      let id = match fields.get("id") {
        Some(Json::Number(number, ..)) => number.to_int()
        _ => -1
      }
      let command = match fields.get("command") {
        Some(Json::String(name)) => name
        _ => ""
      }
      if id < 0 || command.is_empty() {
        emit(harness_reply(id, harness_error("invalid request envelope")))
      } else {
        let args = fields.get("args").unwrap_or(Json::object(Map::from_array([])))
        let result : Json = bootstrap_dispatch(
          setup, tasks, boot, config, cwd, group, command, args,
        ) catch {
          err => harness_error(err.to_string())
        }
        emit(harness_reply(id, result))
      }
    }
    _ => emit(harness_reply(-1, harness_error("request must be a JSON object")))
  }
}
