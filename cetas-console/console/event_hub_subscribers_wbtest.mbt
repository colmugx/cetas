///|
/// Malphite M1: two independent clients observe the same ordered session events.
test "event hub broadcasts to independent subscribers" {
  let hub = EventHub::new()
  let client_a : Array[String] = []
  let client_b : Array[String] = []
  let a = hub.subscribe(fn(frame) { client_a.push(frame) })
  let b = hub.subscribe(fn(frame) { client_b.push(frame) })

  hub.emit("session-a", "turn-1", "turn.accepted")
  hub.emit("session-a", "turn-1", "text.delta", extra=[
    ("text", Json::string("hello")),
  ])

  assert_eq(client_a.length(), 2)
  assert_eq(client_b.length(), 2)
  assert_eq(client_a[0], client_b[0])
  assert_eq(client_a[1], client_b[1])
  assert_true(client_a[0].contains("\"turn.accepted\""))
  assert_true(client_a[1].contains("\"text.delta\""))

  hub.unsubscribe(a)
  hub.emit("session-a", "turn-1", "turn.completed")

  assert_eq(client_a.length(), 2)
  assert_eq(client_b.length(), 3)
  assert_true(client_b[2].contains("\"turn.completed\""))

  // Unsubscribing twice, or with an unknown token, cannot affect client B.
  hub.unsubscribe(a)
  hub.unsubscribe("unknown")
  hub.emit("session-a", "turn-2", "turn.accepted")
  assert_eq(client_b.length(), 4)

  hub.unsubscribe(b)
  hub.emit("session-a", "turn-2", "turn.completed")
  assert_eq(client_b.length(), 4)
}

///|
/// Existing native/desktop attach-detach remains independent of Web subscribers.
test "legacy sink detaches without disconnecting subscriptions" {
  let hub = EventHub::new()
  let native : Array[String] = []
  let web : Array[String] = []
  let web_id = hub.subscribe(fn(frame) { web.push(frame) })

  hub.attach(fn(frame) { native.push(frame) })
  hub.emit("session-b", "turn-1", "turn.accepted")
  assert_eq(native.length(), 1)
  assert_eq(web.length(), 1)

  hub.detach()
  hub.emit("session-b", "turn-1", "turn.completed")
  assert_eq(native.length(), 1)
  assert_eq(web.length(), 2)

  hub.unsubscribe(web_id)
}


///|
/// Realtime-only (not persisted to the rolling trace) must also reach both
/// clients. The new client must not implicitly replay any prior frame.
test "out-of-band events fan out without replaying history" {
  let hub = EventHub::new()
  let first : Array[String] = []
  let second : Array[String] = []

  let a = hub.subscribe(fn(frame) { first.push(frame) })
  hub.emit("s", "t", "turn.accepted")
  let b = hub.subscribe(fn(frame) { second.push(frame) })
  assert_eq(second.length(), 0)

  hub.emit_out_of_band("s", "question.pending", extra=[
    ("request_id", Json::string("q1")),
  ])
  assert_eq(first.length(), 2)
  assert_eq(second.length(), 1)
  assert_eq(first[1], second[0])
  assert_true(second[0].contains("\"question.pending\""))

  hub.unsubscribe(b)
  hub.emit_out_of_band("s", "question.resolved")
  assert_eq(first.length(), 3)
  assert_eq(second.length(), 1)
  hub.unsubscribe(a)
}

///|
/// Iteration must be robust if one callback cancels its own subscription.
test "subscription callback can unsubscribe during dispatch" {
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
