///|
/// The session catalog walks every bucket on disk, so it deliberately leaves
/// the replay FIFO: a picker refresh over a giant session farm must never
/// delay transcript paging. This pins the routing split itself; the Go
/// harness tests exercise both routes end-to-end through the real bridge.
test "session catalog leaves the replay fifo" {
  assert_false(native_replay_command("session_catalog"))
  assert_true(native_catalog_command("session_catalog"))
  for command in ["transcript_index", "transcript_page", "transcript_source"] {
    assert_true(native_replay_command(command))
    assert_false(native_catalog_command(command))
  }
  // Everything else stays on the synchronous dispatch path.
  assert_false(native_replay_command("health"))
  assert_false(native_catalog_command("health"))
  assert_false(native_replay_command("sessions"))
  assert_false(native_catalog_command("sessions"))
}

///|
/// Supersede drops exactly the queued reads that target a departed session
/// and keeps everything else: the switched-to session's jobs, selector-less
/// jobs, and (by construction) the one the worker already holds.
fn job(id : Int32, session : String) -> NativeReplayJob {
  {
    id,
    command: "transcript_page",
    args: if session.is_empty() {
      Json::empty_object()
    } else {
      Json::object({ "session_id": Json::string(session) })
    },
  }
}

///|
fn drain_replay_jobs(tasks : NativeReplayTasks) -> Array[Int32] {
  let ids = []
  while tasks.dequeue() is Some(job) {
    ids.push(job.id)
  }
  ids
}

///|
test "supersede drops only the departed session's queued reads" {
  let tasks = NativeReplayTasks::new("native replay")
  assert_true(tasks.enqueue(job(1, "old")))
  assert_true(tasks.enqueue(job(2, "next")))
  assert_true(tasks.enqueue(job(3, "next")))
  assert_true(tasks.enqueue(job(4, "")))
  assert_eq(tasks.discard_superseded("next").map(j => j.id), [1])
  assert_true(tasks.discard_superseded("next").is_empty())
  assert_eq(drain_replay_jobs(tasks), [2, 3, 4])
  assert_true(tasks.discard_superseded("other").is_empty())
}

///|
test "starting a new session drops every queued session-bound read" {
  let tasks = NativeReplayTasks::new("native replay")
  assert_true(tasks.enqueue(job(1, "old")))
  assert_true(tasks.enqueue(job(2, "")))
  assert_true(tasks.enqueue(job(3, "other")))
  assert_eq(tasks.discard_superseded("").map(j => j.id), [1, 3])
  assert_eq(drain_replay_jobs(tasks), [2])
}

///|
test "replay FIFO preserves order and capacity across wraparound" {
  let tasks = NativeReplayTasks::new("native replay")
  for id in 0..<16 {
    assert_true(tasks.enqueue(job(id, "")))
  }
  assert_false(tasks.enqueue(job(16, "")))
  for id in 0..<8 {
    assert_eq(tasks.dequeue().map(j => j.id), Some(id))
  }
  for id in 16..<24 {
    assert_true(tasks.enqueue(job(id, "")))
  }
  assert_false(tasks.enqueue(job(24, "")))
  assert_true(tasks.discard_superseded("new").is_empty())
  assert_eq(drain_replay_jobs(tasks), [
    8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
  ])
  assert_true(tasks.dequeue() is None)
}
