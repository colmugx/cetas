///|
test "event hub broadcasts to independent subscribers" {
  let hub = EventHub::new()
  let client_a : Array[String] = []
  let client_b : Array[String] = []
  let a = hub.subscribe(fn(frame) { client_a.push(frame) })
  let b = hub.subscribe(fn(frame) { client_b.push(frame) })
  hub.emit("session-a", "turn-1", "turn.accepted")
  hub.emit("session-a", "turn-1", "text.delta")
  assert_eq(client_a.length(), 2)
  assert_eq(client_b.length(), 2)
  assert_eq(client_a[0], client_b[0])
  assert_eq(client_a[1], client_b[1])
  hub.unsubscribe(a)
  hub.emit("session-a", "turn-1", "turn.completed")
  assert_eq(client_a.length(), 2)
  assert_eq(client_b.length(), 3)
  hub.unsubscribe(b)
}

///|
test "legacy sink and web subscriptions detach independently" {
  let hub = EventHub::new()
  let native : Array[String] = []
  let web : Array[String] = []
  let web_id = hub.subscribe(fn(frame) { web.push(frame) })
  hub.attach(fn(frame) { native.push(frame) })
  hub.emit("s", "t", "turn.accepted")
  assert_eq(native.length(), 1)
  assert_eq(web.length(), 1)
  hub.detach()
  hub.emit("s", "t", "turn.completed")
  assert_eq(native.length(), 1)
  assert_eq(web.length(), 2)
  hub.unsubscribe(web_id)
}

///|
test "connection-scoped event never leaks to other subscribers" {
  let hub = EventHub::new()
  let first : Array[String] = []
  let second : Array[String] = []
  let a = hub.subscribe(fn(frame) { first.push(frame) })
  let b = hub.subscribe(fn(frame) { second.push(frame) })
  hub.emit_to(b, "", "connection.ready")
  assert_eq(first.length(), 0)
  assert_eq(second.length(), 1)
  hub.emit("s", "t", "turn.accepted")
  assert_eq(first.length(), 1)
  assert_eq(second.length(), 2)
  hub.unsubscribe(a)
  hub.unsubscribe(b)
}

///|
test "session-scoped subscribers only receive their attached session" {
  let hub = EventHub::new()
  let first : Array[String] = []
  let second : Array[String] = []
  let a = hub.subscribe(fn(frame) { first.push(frame) })
  let b = hub.subscribe(fn(frame) { second.push(frame) })
  hub.filter_session(a, "session-a")
  hub.filter_session(b, "session-b")
  hub.emit("session-a", "turn-1", "turn.accepted")
  hub.emit("session-b", "turn-2", "turn.accepted")
  assert_eq(first.length(), 1)
  assert_eq(second.length(), 1)
  assert_true(first[0].contains("session-a"))
  assert_true(second[0].contains("session-b"))
  hub.emit_to(a, "session-a", "session.snapshot")
  assert_eq(first.length(), 2)
  assert_eq(second.length(), 1)
  hub.unsubscribe(a)
  hub.unsubscribe(b)
}

///|
fn event_cursor_field(raw : String, key : String) -> Json {
  let parsed = @json.parse(raw) catch { _ => Json::null() }
  match parsed {
    Json::Object(fields) => fields.get(key).unwrap_or(Json::null())
    _ => Json::null()
  }
}

///|
test "event hub snapshots expose runtime epoch and per-session high water" {
  let hub = EventHub::new()
  let frames : Array[String] = []
  let sub = hub.subscribe(fn(frame) { frames.push(frame) })
  hub.filter_session(sub, "session-a")
  hub.emit("session-a", "t-1", "turn.accepted")
  hub.emit("session-b", "t-2", "turn.accepted")
  let before = event_cursor_field(frames[0], "cursor")
  assert_eq(before, Json::number(1.0))
  assert_eq(
    event_cursor_field(frames[0], "cursor_advance"),
    Json::boolean(true),
  )
  let epoch = event_cursor_field(frames[0], "runtime_epoch")
  assert_true(epoch is Json::String(_))
  hub.emit_to(sub, "session-a", "session.snapshot")
  let snapshot = frames[1]
  assert_eq(event_cursor_field(snapshot, "cursor"), Json::number(1.0))
  assert_eq(
    event_cursor_field(snapshot, "high_water_cursor"),
    Json::number(1.0),
  )
  assert_eq(
    event_cursor_field(snapshot, "cursor_advance"),
    Json::boolean(false),
  )
  assert_eq(event_cursor_field(snapshot, "runtime_epoch"), epoch)
  hub.emit("session-a", "t-1", "assistant.text_delta")
  assert_eq(event_cursor_field(frames[2], "cursor"), Json::number(2.0))
  assert_eq(event_cursor_field(frames[2], "runtime_epoch"), epoch)
  hub.unsubscribe(sub)
}

///|
/// Realtime-only frames advance the per-Session broadcast cursor and fan out
/// to existing subscribers, without replaying earlier frames to a late peer.
test "out-of-band events reach existing subscribers without replaying history" {
  let hub = EventHub::new()
  let first : Array[String] = []
  let second : Array[String] = []
  let a = hub.subscribe(fn(frame) { first.push(frame) })
  hub.emit("s", "t", "turn.accepted")
  let b = hub.subscribe(fn(frame) { second.push(frame) })
  assert_eq(second.length(), 0)
  hub.emit_out_of_band("s", "question.pending")
  assert_eq(first.length(), 2)
  assert_eq(second.length(), 1)
  assert_eq(first[1], second[0])
  assert_eq(event_cursor_field(first[1], "cursor"), Json::number(2.0))
  assert_eq(
    event_cursor_field(first[1], "cursor_advance"),
    Json::boolean(true),
  )
  hub.unsubscribe(b)
  hub.emit_out_of_band("s", "question.resolved")
  assert_eq(first.length(), 3)
  assert_eq(second.length(), 1)
  hub.unsubscribe(a)
}

///|
/// Removing a subscriber during dispatch must not mutate the iterator,
/// suppress the other subscriber, or re-deliver on the following broadcast.
test "subscriber can cancel itself during event delivery" {
  let hub = EventHub::new()
  let self_id = Ref("")
  let first : Array[String] = []
  let second : Array[String] = []
  let a = hub.subscribe(fn(frame) {
    first.push(frame)
    hub.unsubscribe(self_id.val)
  })
  self_id.val = a
  let b = hub.subscribe(fn(frame) { second.push(frame) })
  hub.emit("s", "", "statusbar.step")
  hub.emit("s", "", "statusbar.step")
  assert_eq(first.length(), 1)
  assert_eq(second.length(), 2)
  hub.unsubscribe(b)
}
