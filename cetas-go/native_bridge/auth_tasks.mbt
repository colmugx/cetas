///|
priv struct NativeAuthAttempt {
  id : String
  mut task : @core_async.Task[Unit]?
  mut cancelled : Bool
}

///|
priv enum NativeAuthSlot {
  Idle
  Active(NativeAuthAttempt)
}

///|
/// Provider sign-in must not monopolize the command dispatcher: login_cancel
/// and ui_response must remain serviceable while OAuth polls.
priv struct NativeAuthTasks {
  mut next_id : Int32
  mut slot : NativeAuthSlot
}

///|
fn NativeAuthTasks::new() -> NativeAuthTasks {
  { next_id: 1, slot: Idle, }
}

///|
fn NativeAuthTasks::clear(self : NativeAuthTasks, id : String) -> Unit {
  if self.slot is Active(attempt) && attempt.id == id {
    self.slot = Idle
  }
}

///|
fn NativeAuthTasks::start_flow(
  self : NativeAuthTasks,
  group : @core_async.TaskGroup,
  run : async () -> Json,
  complete : (String, Json) -> Unit,
) -> String? {
  let previous = match self.slot {
    Idle => None
    Active(attempt) if attempt.cancelled => attempt.task
    Active(_) => return None
  }
  let id = "auth-\{self.next_id}"
  self.next_id += 1
  let attempt = { id, task: None, cancelled: false, }
  self.slot = Active(attempt)
  attempt.task = Some(
    group.spawn(
      async fn() {
        defer (if !attempt.cancelled { self.clear(id) })
        // Wait outside the dispatcher. Even if this replacement is cancelled, it
        // must not settle before its predecessor releases the terminal.
        if previous is Some(task) {
          @core_async.protect_from_cancel(async fn() {
            task.wait() catch {
              _ => ()
            }
          })
        }
        guard !attempt.cancelled && !@core_async.is_being_cancelled() else {
          return
        }
        let result = run()
        if !attempt.cancelled {
          complete(id, result)
        }
      },
      allow_failure=true,
    ),
  )
  Some(id)
}

///|
fn NativeAuthTasks::start(
  self : NativeAuthTasks,
  runtime : @console.ConsoleRuntime,
  group : @core_async.TaskGroup,
  provider : String,
  run : async () -> Json,
) -> Json {
  let session_id = runtime.active_session_id()
  guard self.start_flow(group, run, (id, result) => {
      runtime.emit_event(session_id, "", "auth.login", extra=[
        ("auth_id", Json::string(id)),
        ("provider", Json::string(provider)),
        ("result", result),
      ])
    })
    is Some(id) else {
    return harness_error("another provider login is already active")
  }
  Json::object({
    "status": Json::string("started"),
    "auth_id": Json::string(id),
    "provider": Json::string(provider),
    "session_id": Json::string(session_id),
  })
}

///|
fn NativeAuthTasks::cancel(
  self : NativeAuthTasks,
  group : @core_async.TaskGroup,
  id : String,
  complete : () -> Unit,
) -> Bool {
  guard self.slot is Active(attempt) &&
    attempt.id == id &&
    !attempt.cancelled &&
    attempt.task is Some(task) else {
    return false
  }
  attempt.cancelled = true
  task.cancel()
  // Joining handles cancellation before the task body starts, too. Notify the
  // UI only once the provider flow is no longer holding the terminal.
  group.spawn_bg(
    async fn() {
      task.wait() catch {
        _ => ()
      }
      self.clear(id)
      complete()
    },
    allow_failure=true,
  )
  true
}

///|
fn NativeAuthTasks::cancel_all(self : NativeAuthTasks) -> Unit {
  if self.slot is Active(attempt) {
    attempt.cancelled = true
    if attempt.task is Some(task) {
      task.cancel()
    }
  }
}
