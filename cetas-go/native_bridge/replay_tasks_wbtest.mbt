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
  let fields : Array[(String, Json)] = []
  if session != "" {
    fields.push(("session_id", Json::string(session)))
  }
  {
    id,
    command: "transcript_page",
    args: Json::object(Map::from_array(fields)),
  }
}

///|
test "supersede drops only the departed session's queued reads" {
  let tasks = NativeReplayTasks::new("native replay")
  tasks.queue.push(job(1, "old"))
  tasks.queue.push(job(2, "next"))
  tasks.queue.push(job(3, "next"))
  tasks.queue.push(job(4, ""))
  // The emit half needs the host sink, so pin the pure split: the departed
  // session's jobs drop, the target's and selector-less jobs stay.
  let (kept, dropped) = tasks.split_superseded("next")
  assert_eq(kept.map(j => j.id), [2, 3, 4])
  assert_eq(dropped.map(j => j.id), [1])
  // Repeat sweeps against a different keeper are idempotent, and the empty
  // queue is a no-op.
  tasks.queue = kept
  let (kept2, dropped2) = tasks.split_superseded("other")
  assert_eq(kept2.map(j => j.id), [4])
  assert_eq(dropped2.map(j => j.id), [2, 3])
  tasks.queue = []
  let (kept3, dropped3) = tasks.split_superseded("whoever")
  assert_true(kept3.is_empty())
  assert_true(dropped3.is_empty())
}
