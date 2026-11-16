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
