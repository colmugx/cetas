///|
/// Only the native harness owns these Task handles. Provider sign-in must not
/// monopolize the command dispatcher: in particular login_cancel and
/// ui_response must remain serviceable while OAuth polls.
priv struct NativeAuthTasks {
  mut next_id : Int32
  pending : Map[String, @core_async.Task[Unit]]
  cancelled : Map[String, Bool]
}

///|
fn NativeAuthTasks::new() -> NativeAuthTasks {
  { next_id: 1, pending: Map([]), cancelled: Map([]), }
}

///|
fn NativeAuthTasks::busy(self : NativeAuthTasks) -> Bool {
  for _, _ in self.pending {
    return true
  }
  false
}

///|
/// Only one login at once: two simultaneous provider flows would otherwise
/// race to own the same terminal, and their OAuth notices would interleave.
fn NativeAuthTasks::start(
  self : NativeAuthTasks,
  runtime : @console.ConsoleRuntime,
  group : @core_async.TaskGroup,
  provider : String,
  auth_method : String,
) -> Json {
  if self.busy() {
    return harness_error("another provider login is already active")
  }
  let id = "auth-" + self.next_id.to_string()
  self.next_id += 1
  let session_id = runtime.active_session_id()
  let task = group.spawn(
    () => {
      // Release the single-flight slot only when the child actually settles.
      // A cancellation before provider polling finishes must not make a
      // second OAuth flow eligible to start.
      defer {
        self.pending.remove(id)
        self.cancelled.remove(id)
      }
      let result = runtime.login(provider, auth_method)
      if !self.cancelled.contains(id) {
        runtime.emit_event(session_id, "", "auth.login", extra=[
          ("auth_id", Json::string(id)),
          ("provider", Json::string(provider)),
          ("result", harness_console_json(result)),
        ])
      }
    },
    allow_failure=true,
  )
  self.pending[id] = task
  Json::object(
    Map::from_array([
      ("status", Json::string("started")),
      ("auth_id", Json::string(id)),
      ("provider", Json::string(provider)),
      ("session_id", Json::string(session_id)),
    ]),
  )
}

///|
/// Explicit cancellation never waits on the child task in the command loop:
/// that task may still be suspending in a provider's OAuth poll. It is owned
/// by the enclosing TaskGroup[Unit], which drains it on host shutdown.
fn NativeAuthTasks::cancel(
  self : NativeAuthTasks,
  runtime : @console.ConsoleRuntime,
  id : String,
) -> Bool {
  match self.pending.get(id) {
    Some(task) => {
      if self.cancelled.contains(id) {
        return false
      }
      self.cancelled[id] = true
      task.cancel()
      // A cancellation can occur before the spawned body first runs. In that
      // case its defer cannot fire. Join in a separate background coroutine,
      // never in the native command dispatcher itself.
      runtime.spawn_background(async fn() {
        let _ = task.wait() catch { _ => () }
        self.pending.remove(id)
        self.cancelled.remove(id)
      })
      runtime.emit_event(runtime.active_session_id(), "", "auth.cancelled", extra=[
        ("auth_id", Json::string(id)),
      ])
      true
    }
    None => false
  }
}

///|
/// Stop polling before the host detaches its event sink and drains the group.
/// Other runtime tasks remain owned by their existing shutdown paths.
fn NativeAuthTasks::cancel_all(self : NativeAuthTasks) -> Unit {
  let ids : Array[String] = []
  for id, _ in self.pending {
    ids.push(id)
  }
  for id in ids {
    match self.pending.get(id) {
      Some(task) => {
        self.cancelled[id] = true
        task.cancel()
        // Keep the cancellation tombstone until the task settles. Even if
        // provider polling returns late during shutdown, it cannot publish a
        // successful login after the terminal has stopped accepting input.
      }
      None => ()
    }
  }
}
