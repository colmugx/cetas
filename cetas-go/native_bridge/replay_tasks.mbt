///|
/// Replay reads share the one MoonBit domain but never monopolize its command
/// dispatcher. A single worker serializes file/index access; at most sixteen
/// requests wait behind it. No goroutine owns or touches a MoonBit object.
/// `label` names the worker in queue/refusal errors so a host can tell which
/// surface rejected a request.
priv struct NativeReplayJob {
  id : Int32
  command : String
  args : Json
}

///|
priv struct NativeReplayTasks {
  label : String
  queue : FixedArray[NativeReplayJob?]
  mut head : Int32
  mut pending : Int32
  mut worker : @core_async.Task[Unit]?
  mut active : Int32?
  mut stopped : Bool
}

///|
fn NativeReplayTasks::new(label : String) -> NativeReplayTasks {
  {
    label,
    queue: FixedArray::make(16, None),
    head: 0,
    pending: 0,
    worker: None,
    active: None,
    stopped: false,
  }
}

///|
fn NativeReplayTasks::enqueue(
  self : NativeReplayTasks,
  job : NativeReplayJob,
) -> Bool {
  let capacity = self.queue.length()
  guard self.pending < capacity else { return false }
  self.queue[(self.head + self.pending) % capacity] = Some(job)
  self.pending += 1
  true
}

///|
fn NativeReplayTasks::dequeue(self : NativeReplayTasks) -> NativeReplayJob? {
  guard self.pending > 0 else { return None }
  let job = self.queue[self.head]
  self.queue[self.head] = None
  self.head = (self.head + 1) % self.queue.length()
  self.pending -= 1
  job
}

///|
fn native_replay_command(command : String) -> Bool {
  command == "transcript_index" ||
  command == "transcript_page" ||
  command == "transcript_source"
}

///|
/// The session catalog walks every bucket on disk, so it never shares the
/// replay FIFO: a picker refresh over a giant session farm must not delay
/// transcript paging, and vice versa.
fn native_catalog_command(command : String) -> Bool {
  command == "session_catalog"
}

///|
fn NativeReplayTasks::submit(
  self : NativeReplayTasks,
  runtime : @console.ConsoleRuntime,
  auth_tasks : NativeAuthTasks,
  group : @core_async.TaskGroup,
  id : Int32,
  command : String,
  args : Json,
) -> Unit {
  if self.stopped {
    emit(harness_reply(id, harness_error("\{self.label} worker has stopped")))
    return
  }
  if !self.enqueue({ id, command, args, }) {
    emit(
      harness_reply(
        id,
        harness_error(
          "\{self.label} request queue is full (\{self.queue.length()} pending)",
        ),
      ),
    )
    return
  }
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
        while !self.stopped && self.dequeue() is Some(job) {
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
/// Sweep only the queued jobs, appending survivors in their original order.
fn NativeReplayTasks::discard_superseded(
  self : NativeReplayTasks,
  keep : String,
) -> Array[NativeReplayJob] {
  let dropped : Array[NativeReplayJob] = []
  for _ in 0..<self.pending {
    guard self.dequeue() is Some(job) else { break }
    let session = harness_session_arg(job.args).unwrap_or("")
    if session != "" && session != keep {
      dropped.push(job)
    } else {
      ignore(self.enqueue(job))
    }
  }
  dropped
}

///|
/// A session switch makes queued reads for every other session stale: the UI
/// that requested them is being torn down and would reject their replies
/// anyway. Dropping them with a named error keeps the FIFO clear for the
/// switched-to session's first reads. A job without a session selector is
/// kept, and the job the worker already holds still runs to completion.
fn NativeReplayTasks::supersede(
  self : NativeReplayTasks,
  keep : String,
) -> Unit {
  if self.stopped || self.pending == 0 {
    return
  }
  for job in self.discard_superseded(keep) {
    emit(
      harness_reply(
        job.id,
        harness_error("\{self.label} request superseded by session switch"),
      ),
    )
  }
}

///|
/// Settle queued/in-flight request ids before detaching the sink. Cancellation
/// belongs to the host TaskGroup[Unit], which drains the worker and its async files.
fn NativeReplayTasks::cancel_all(self : NativeReplayTasks) -> Unit {
  self.stopped = true
  while self.dequeue() is Some(job) {
    emit(
      harness_reply(
        job.id,
        harness_error("\{self.label} cancelled during shutdown"),
      ),
    )
  }
  match self.active {
    Some(id) =>
      emit(
        harness_reply(
          id,
          harness_error("\{self.label} cancelled during shutdown"),
        ),
      )
    None => ()
  }
  match self.worker {
    Some(task) => task.cancel()
    None => ()
  }
}
