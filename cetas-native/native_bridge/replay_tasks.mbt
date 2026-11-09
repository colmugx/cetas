///|
/// Replay reads share the one MoonBit domain but never monopolize its command
/// dispatcher. A single worker serializes file/index access; at most sixteen
/// requests wait behind it. No goroutine owns or touches a MoonBit object.
priv struct NativeReplayJob {
  id : Int32
  command : String
  args : Json
}

///|
priv struct NativeReplayTasks {
  mut queue : Array[NativeReplayJob]
  mut worker : @async.Task[Unit]?
  mut active : Int32?
  mut stopped : Bool
}

///|
fn NativeReplayTasks::new() -> NativeReplayTasks {
  { queue: [], worker: None, active: None, stopped: false, }
}

///|
fn native_replay_command(command : String) -> Bool {
  command == "transcript_index" ||
  command == "transcript_page" ||
  command == "transcript_source" ||
  command == "session_catalog"
}

///|
fn NativeReplayTasks::submit(
  self : NativeReplayTasks,
  runtime : @console.ConsoleRuntime,
  auth_tasks : NativeAuthTasks,
  group : @async.TaskGroup[Unit],
  id : Int32,
  command : String,
  args : Json,
) -> Unit {
  if self.stopped {
    emit(harness_reply(id, harness_error("native replay worker has stopped")))
    return
  }
  if self.queue.length() >= 16 {
    emit(
      harness_reply(
        id,
        harness_error("native replay request queue is full (16 pending)"),
      ),
    )
    return
  }
  self.queue.push({ id, command, args, })
  if self.worker is Some(_) {
    return
  }
  self.worker = Some(
    group.spawn(
      async fn() {
        defer {
          self.active = None
          self.worker = None
        }
        while !self.stopped && !self.queue.is_empty() {
          let pending = self.queue
          let job = pending[0]
          // This queue is deliberately tiny; replacing the tail also releases the
          // completed request rather than retaining an ever-growing head cursor.
          self.queue = []
          for index in 1..<pending.length() {
            self.queue.push(pending[index])
          }
          self.active = Some(job.id)
          let result = harness_dispatch(
            runtime,
            auth_tasks,
            group,
            job.command,
            job.args,
          ) catch {
            error => harness_error(error.to_string())
          }
          if !self.stopped {
            emit(harness_reply(job.id, result))
          }
          self.active = None
        }
      },
      allow_failure=true,
    ),
  )
}

///|
/// Settle queued/in-flight request ids before detaching the sink. Cancellation
/// belongs to the host TaskGroup, which drains the worker and its async files.
fn NativeReplayTasks::cancel_all(self : NativeReplayTasks) -> Unit {
  self.stopped = true
  for job in self.queue {
    emit(
      harness_reply(
        job.id,
        harness_error("native replay cancelled during shutdown"),
      ),
    )
  }
  self.queue = []
  match self.active {
    Some(id) =>
      emit(
        harness_reply(
          id,
          harness_error("native replay cancelled during shutdown"),
        ),
      )
    None => ()
  }
  match self.worker {
    Some(task) => task.cancel()
    None => ()
  }
}
