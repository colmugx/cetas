///|
/// Field of a JSON object, or `null` when the payload is not an object.
fn trace_budget_field(json : Json, key : String) -> Json {
  match json {
    Json::Object(fields) =>
      match fields.get(key) {
        Some(value) => value
        None => Json::null()
      }
    _ => Json::null()
  }
}

///|
fn trace_budget_int(json : Json, key : String) -> Int32 {
  match trace_budget_field(json, key) {
    Json::Number(value, ..) => value.to_int()
    _ => abort("trace retention report must carry an integer \{key}")
  }
}

///|
fn trace_budget_bool(json : Json, key : String) -> Bool {
  match trace_budget_field(json, key) {
    Json::True => true
    Json::False => false
    _ => abort("trace retention report must carry a boolean \{key}")
  }
}

///|
fn trace_budget_string(json : Json, key : String) -> String {
  match trace_budget_field(json, key) {
    Json::String(value) => value
    _ => ""
  }
}

///|
/// Parse one captured wire frame. A frame that is not JSON, or not an object,
/// is already a wire regression; aborting here keeps the seam honest.
fn trace_budget_frame(raw : String) -> Json {
  @json.parse(raw) catch {
    _ => abort("captured wire frame must be JSON")
  }
}

///|
/// Ledger frames carry their session and turn attribution; this is the smallest
/// deterministic shape two runs can be compared on (`ts` is a clock read).
fn trace_budget_wire_shape(raw : Array[String]) -> Array[String] {
  raw.map(frame => {
    let parsed = trace_budget_frame(frame)
    trace_budget_string(parsed, "type") +
    "#" +
    trace_budget_int(parsed, "seq").to_string() +
    "#" +
    trace_budget_string(parsed, "event_id") +
    "#" +
    trace_budget_string(parsed, "session_id") +
    "#" +
    trace_budget_string(parsed, "turn_id") +
    "#" +
    trace_budget_string(parsed, "delta")
  })
}

///|
/// Attach the captured sink the assertions are written against: the wire is the
/// one surface a budget may never shrink.
fn trace_budget_capture(hub : EventHub) -> Array[String] {
  let raw : Array[String] = []
  hub.attach(fn(frame) { raw.push(frame) })
  raw
}

///|
/// The budget is an explicit host opt-in, so the shared web contract stays
/// exactly as it was: a 600-frame rolling log by count, complete ledgers, and a
/// report that says "not trimmed" because nothing is dropped.
test "native retention off keeps every ledger and reports completeness" {
  let hub = EventHub::new()
  assert_true(hub.retention is None)
  let raw = trace_budget_capture(hub)
  hub.emit("session-a", "t-1", "turn.accepted", extra=[
    ("prompt", Json::string("hi")),
  ])
  for i in 0..<700 {
    hub.emit("session-a", "t-1", "assistant.text_delta", extra=[
      ("delta", Json::string("d-" + i.to_string())),
    ])
  }
  // Shared web contract: the rolling log is a 600-frame window by count only.
  assert_eq(hub.trace.length(), 600)
  // The turn ledger is untouched — this is what the trace page reads today.
  let ledger = hub.turn_traces.get("session-a/t-1").unwrap()
  assert_eq(ledger.length(), 701)
  // Wire first: every frame reached the sink, in order, complete.
  assert_eq(raw.length(), 701)
  assert_eq(trace_budget_string(trace_budget_frame(raw[700]), "delta"), "d-699")
  // Explicit metadata, not silence: no budget ran, nothing was dropped.
  let report = hub.retention_json()
  assert_false(trace_budget_bool(report, "enabled"))
  assert_false(trace_budget_bool(report, "trimmed"))
  let turn = hub.turn_retention_json("session-a/t-1")
  assert_eq(trace_budget_int(turn, "retained_events"), 701)
  assert_eq(trace_budget_int(turn, "dropped_events"), 0)
  assert_false(trace_budget_bool(turn, "trimmed"))
}

///|
/// Count window on the rolling log: the older frames leave the diagnostic log
/// while the sink keeps receiving all of them.
test "native retention bounds the rolling trace by frame count" {
  let hub = EventHub::new()
  hub.enable_native_retention(budget={
    trace_frames: 8,
    trace_size: 1024 * 1024,
    turn_events: 2048,
    turn_size: 256 * 1024,
    session_turns: 64,
    total_size: 1024 * 1024,
  })
  let raw = trace_budget_capture(hub)
  for i in 0..<200 {
    hub.emit("session-a", "", "assistant.text_delta", extra=[
      ("delta", Json::string("d-" + i.to_string())),
    ])
  }
  assert_eq(hub.trace.length(), 8)
  assert_eq(raw.length(), 200)
  let trace = trace_budget_field(hub.retention_json(), "trace")
  assert_eq(trace_budget_int(trace, "retained_frames"), 8)
  assert_eq(trace_budget_int(trace, "dropped_frames"), 192)
  // The retained window is the *newest* 8 frames, so a reader sees the ending.
  assert_eq(trace_budget_string(hub.trace[0], "delta"), "d-192")
  assert_eq(trace_budget_string(hub.trace[7], "delta"), "d-199")
}

///|
/// Size window on the rolling log: the frame cap is generous here, so only the
/// serialized-size cap can hold the log — the case a frame-count cap misses.
test "native retention bounds the rolling trace by size" {
  let hub = EventHub::new()
  hub.enable_native_retention(budget={
    trace_frames: 600,
    trace_size: 4 * 1024,
    turn_events: 2048,
    turn_size: 256 * 1024,
    session_turns: 64,
    total_size: 1024 * 1024,
  })
  let raw = trace_budget_capture(hub)
  let payload = "x".repeat(400)
  for i in 0..<200 {
    hub.emit("session-a", "", "assistant.text_delta", extra=[
      ("delta", Json::string(payload + i.to_string())),
    ])
  }
  assert_eq(raw.length(), 200)
  assert_true(hub.trace.length() < 20)
  let trace = trace_budget_field(hub.retention_json(), "trace")
  assert_true(trace_budget_int(trace, "retained_size") <= 4 * 1024)
  assert_true(trace_budget_int(trace, "dropped_frames") > 0)
  // Wire never loses the frame that did not fit the diagnostic window.
  assert_eq(
    trace_budget_string(trace_budget_frame(raw[199]), "delta").length(),
    (payload + "199").length(),
  )
}

///|
/// One frame larger than the whole window: a hard cap wins over the single
/// frame, and the report says so. The wire still carries it whole.
test "native retention drops one oversized frame rather than exceed the cap" {
  let hub = EventHub::new()
  hub.enable_native_retention(budget={
    trace_frames: 600,
    trace_size: 1024,
    turn_events: 2048,
    turn_size: 1024 * 1024,
    session_turns: 64,
    total_size: 4 * 1024 * 1024,
  })
  let raw = trace_budget_capture(hub)
  let huge = "y".repeat(64 * 1024)
  hub.emit("session-a", "", "tool.completed", extra=[
    ("result", Json::string(huge)),
  ])
  assert_true(hub.trace.is_empty())
  assert_eq(raw.length(), 1)
  assert_eq(
    trace_budget_string(trace_budget_frame(raw[0]), "result").length(),
    huge.length(),
  )
  let trace = trace_budget_field(hub.retention_json(), "trace")
  assert_eq(trace_budget_int(trace, "retained_frames"), 0)
  assert_eq(trace_budget_int(trace, "dropped_frames"), 1)
  assert_true(trace_budget_bool(hub.retention_json(), "trimmed"))
}

///|
/// One turn with thousands of deltas: the ledger window keeps the newest events
/// and says how many it dropped, so the trace consumer can label the turn as
/// trimmed instead of presenting it as the complete path.
test "one turn with thousands of deltas stays inside the ledger budget" {
  let hub = EventHub::new()
  // Serialized size is generous here, so only the event cap can hold the ledger.
  hub.enable_native_retention(budget={
    trace_frames: 600,
    trace_size: 1024 * 1024,
    turn_events: 64,
    turn_size: 256 * 1024,
    session_turns: 64,
    total_size: 1024 * 1024,
  })
  let raw = trace_budget_capture(hub)
  hub.emit("session-a", "t-1", "turn.accepted", extra=[
    ("prompt", Json::string("count to 5000")),
  ])
  for i in 0..<5000 {
    hub.emit("session-a", "t-1", "assistant.text_delta", extra=[
      ("delta", Json::string("chunk-" + i.to_string())),
    ])
  }
  let ledger = hub.turn_traces.get("session-a/t-1").unwrap()
  assert_eq(ledger.length(), 64)
  assert_eq(raw.length(), 5001)
  // Retained frames are the same objects the wire carried — never truncated.
  assert_eq(ledger[63].stringify(), raw[5000])
  assert_eq(trace_budget_string(ledger[63], "delta"), "chunk-4999")
  let turn = hub.turn_retention_json("session-a/t-1")
  assert_eq(trace_budget_int(turn, "retained_events"), 64)
  assert_eq(trace_budget_int(turn, "dropped_events"), 5001 - 64)
  assert_true(trace_budget_bool(turn, "trimmed"))
  let ledgers = trace_budget_field(hub.retention_json(), "ledgers")
  assert_eq(trace_budget_int(ledgers, "dropped_events"), 5001 - 64)
  assert_true(trace_budget_bool(hub.retention_json(), "trimmed"))
}

///|
/// Per-turn size window: the event cap is generous, so the turn's own bytes have
/// to bound it — the other shape a turn-count cap misses.
test "a single heavy turn is bounded by its serialized size" {
  let hub = EventHub::new()
  hub.enable_native_retention(budget={
    trace_frames: 600,
    trace_size: 1024 * 1024,
    turn_events: 4096,
    turn_size: 2 * 1024,
    session_turns: 64,
    total_size: 1024 * 1024,
  })
  let raw = trace_budget_capture(hub)
  hub.emit("session-a", "t-1", "turn.accepted", extra=[
    ("prompt", Json::string("big")),
  ])
  let payload = "z".repeat(200)
  for _ in 0..<100 {
    hub.emit("session-a", "t-1", "tool.completed", extra=[
      ("result", Json::string(payload)),
    ])
  }
  let ledger = hub.turn_traces.get("session-a/t-1").unwrap()
  assert_true(ledger.length() < 12)
  let retained : Int32 = ledger.fold(init=0, (sum, frame) => {
    sum + frame.stringify().length()
  })
  assert_true(retained <= 2 * 1024)
  assert_eq(raw.length(), 101)
  let turn = hub.turn_retention_json("session-a/t-1")
  assert_eq(trace_budget_int(turn, "retained_events"), ledger.length())
  assert_eq(trace_budget_int(turn, "dropped_events"), 101 - ledger.length())
}

///|
/// Per-session turn window: the oldest turns leave the order list and the ledger
/// map together, so the trace projection cannot see half a turn.
test "a session keeps only its newest turns" {
  let hub = EventHub::new()
  hub.enable_native_retention(budget={
    trace_frames: 600,
    trace_size: 1024 * 1024,
    turn_events: 2048,
    turn_size: 256 * 1024,
    session_turns: 3,
    total_size: 1024 * 1024,
  })
  let raw = trace_budget_capture(hub)
  for turn in 0..<10 {
    let turn_id = "t-" + turn.to_string()
    hub.emit("session-a", turn_id, "turn.accepted", extra=[
      ("prompt", Json::string("go")),
    ])
    hub.emit("session-a", turn_id, "assistant.text_delta", extra=[
      ("delta", Json::string("done")),
    ])
  }
  assert_eq(hub.turn_order.get("session-a").unwrap(), [
    "session-a/t-7", "session-a/t-8", "session-a/t-9",
  ])
  assert_eq(hub.turn_traces.length(), 3)
  assert_true(hub.turn_traces.get("session-a/t-0") is None)
  let ledgers = trace_budget_field(hub.retention_json(), "ledgers")
  assert_eq(trace_budget_int(ledgers, "retained_turns"), 3)
  assert_eq(trace_budget_int(ledgers, "dropped_turns"), 7)
  // The wire carried all 20 frames regardless of what the ledgers kept.
  assert_eq(raw.length(), 20)
}

///|
/// Orphan facts (session-scoped, before any accepted turn) are pruned by the
/// same window instead of growing one bucket per session forever.
test "the session orphan bucket is trimmed with the turn window" {
  let hub = EventHub::new()
  hub.enable_native_retention(budget={
    trace_frames: 600,
    trace_size: 1024 * 1024,
    turn_events: 2048,
    turn_size: 256 * 1024,
    session_turns: 2,
    total_size: 1024 * 1024,
  })
  let raw = trace_budget_capture(hub)
  for i in 0..<5 {
    hub.emit("session-a", "t-0", "session.snapshot", extra=[
      ("model", Json::string("m-" + i.to_string())),
    ])
  }
  hub.emit("session-a", "t-1", "turn.accepted", extra=[
    ("prompt", Json::string("hi")),
  ])
  // The orphan bucket stays first in the order list while it fits.
  assert_eq(hub.turn_order.get("session-a").unwrap(), [
    "session-a/", "session-a/t-1",
  ])
  hub.emit("session-a", "t-2", "turn.accepted", extra=[
    ("prompt", Json::string("again")),
  ])
  assert_eq(hub.turn_order.get("session-a").unwrap(), [
    "session-a/t-1", "session-a/t-2",
  ])
  assert_true(hub.turn_traces.get("session-a/") is None)
  assert_eq(hub.turn_traces.length(), 2)
  assert_eq(raw.length(), 7)
}

///|
/// Process-wide window: sessions outlive any per-session cap in one long-lived
/// process, so the total retained ledger bytes need their own bound. The oldest
/// session leaves first.
test "the whole-hub ledger budget bounds many sessions" {
  let hub = EventHub::new()
  hub.enable_native_retention(budget={
    trace_frames: 600,
    trace_size: 1024 * 1024,
    turn_events: 64,
    turn_size: 8 * 1024,
    session_turns: 64,
    total_size: 4 * 1024,
  })
  let raw = trace_budget_capture(hub)
  let payload = "p".repeat(80)
  for session in 0..<10 {
    let session_id = "s-" + session.to_string()
    hub.emit(session_id, "t-1", "turn.accepted", extra=[
      ("prompt", Json::string("hi")),
    ])
    for _ in 0..<20 {
      hub.emit(session_id, "t-1", "tool.completed", extra=[
        ("result", Json::string(payload)),
      ])
    }
  }
  let report = hub.retention_json()
  let ledgers = trace_budget_field(report, "ledgers")
  assert_true(trace_budget_int(ledgers, "retained_size") <= 4 * 1024)
  assert_true(trace_budget_int(ledgers, "dropped_turns") > 0)
  assert_true(trace_budget_bool(report, "trimmed"))
  // The newest turn keeps a bounded tail; the oldest session leaves together
  // with its order slot instead of turning into a dangling projection row.
  let newest = hub.turn_traces.get("s-9/t-1").unwrap()
  assert_true(newest.length() > 0)
  assert_eq(trace_budget_string(newest[newest.length() - 1], "result"), payload)
  assert_true(hub.turn_traces.get("s-0/t-1") is None)
  assert_true(hub.turn_order.get("s-0") is None)
  assert_eq(raw.length(), 10 * 21)
}

///|
/// Everything the budget touches is diagnostic: enabling it changes no frame.
/// The same emit script produces the same wire with the window on and off.
test "enabling native retention does not change the wire" {
  let script = fn(hub : EventHub) -> Array[String] {
    let raw = trace_budget_capture(hub)
    hub.emit("session-a", "", "session.snapshot", extra=[
      ("model", Json::string("m")),
    ])
    hub.emit("session-a", "t-1", "turn.accepted", extra=[
      ("prompt", Json::string("hi")),
    ])
    for i in 0..<300 {
      hub.emit("session-a", "t-1", "assistant.text_delta", extra=[
        ("delta", Json::string("chunk-" + i.to_string())),
      ])
    }
    hub.emit("session-a", "t-1", "turn.completed", extra=[
      ("text", Json::string("done")),
    ])
    hub.emit_out_of_band("session-a", "subagent.event", extra=[
      ("kind", Json::string("child")),
    ])
    raw
  }
  let shared = EventHub::new()
  let shared_wire = script(shared)
  let native = EventHub::new()
  let budget : NativeTraceBudget = {
    trace_frames: 4,
    trace_size: 2 * 1024,
    turn_events: 32,
    turn_size: 2 * 1024,
    session_turns: 1,
    total_size: 2 * 1024,
  }
  native.enable_native_retention(budget~)
  let native_wire = script(native)
  assert_eq(
    trace_budget_wire_shape(shared_wire),
    trace_budget_wire_shape(native_wire),
  )
  // Same wire, different diagnostics: the shared hub still keeps whole ledgers.
  assert_eq(shared.turn_traces.get("session-a/t-1").unwrap().length(), 302)
  assert_true(native.turn_traces.get("session-a/t-1").unwrap().length() <= 32)
  let shared_report = shared.retention_json()
  assert_false(trace_budget_bool(shared_report, "enabled"))
  assert_false(trace_budget_bool(shared_report, "trimmed"))
}

///|
/// A late opt-in (second call, or a hub that already emitted while composing)
/// must adopt what is already retained instead of accounting from zero — the
/// one way these caps could be silently exceeded.
test "enabling the budget later adopts what the hub already retains" {
  let hub = EventHub::new()
  let raw = trace_budget_capture(hub)
  hub.emit("session-a", "t-1", "turn.accepted", extra=[
    ("prompt", Json::string("hi")),
  ])
  for i in 0..<120 {
    hub.emit("session-a", "t-1", "assistant.text_delta", extra=[
      ("delta", Json::string("a-" + i.to_string())),
    ])
  }
  hub.emit("session-b", "t-1", "turn.accepted", extra=[
    ("prompt", Json::string("hi")),
  ])
  for i in 0..<60 {
    hub.emit("session-b", "t-1", "assistant.text_delta", extra=[
      ("delta", Json::string("b-" + i.to_string())),
    ])
  }
  // No budget yet: the shared contract keeps everything.
  assert_eq(hub.trace.length(), 182)
  assert_eq(hub.turn_traces.get("session-a/t-1").unwrap().length(), 121)
  hub.enable_native_retention(budget={
    trace_frames: 4,
    trace_size: 1024 * 1024,
    turn_events: 16,
    turn_size: 256 * 1024,
    session_turns: 2,
    total_size: 1024 * 1024,
  })
  // Bounded right away, oldest first, with the drops reported.
  assert_eq(hub.trace.length(), 4)
  assert_eq(hub.turn_traces.get("session-a/t-1").unwrap().length(), 16)
  assert_eq(hub.turn_traces.get("session-b/t-1").unwrap().length(), 16)
  assert_eq(
    trace_budget_int(hub.turn_retention_json("session-a/t-1"), "dropped_events"),
    121 - 16,
  )
  // The report measures the real retained content, not a counter started at 0.
  let report = hub.retention_json()
  let actual_trace : Int32 = hub.trace.fold(init=0, (sum, frame) => {
    sum + frame.stringify().length()
  })
  assert_eq(
    trace_budget_int(trace_budget_field(report, "trace"), "retained_size"),
    actual_trace,
  )
  let mut actual_ledgers : Int32 = 0
  for _, ledger in hub.turn_traces {
    for frame in ledger {
      actual_ledgers += frame.stringify().length()
    }
  }
  assert_eq(
    trace_budget_int(trace_budget_field(report, "ledgers"), "retained_size"),
    actual_ledgers,
  )
  // Adopting trimmed diagnostics only: the wire still carried every frame.
  assert_eq(raw.length(), 182)
}
