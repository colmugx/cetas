///|
test "native startup warnings reach the first sink once and keep event order" {
  let hub = EventHub::new()
  hub.enable_native_retention()
  hub.native_warning("", "startup context warning")
  let first : Array[String] = []
  hub.attach(fn(frame) { first.push(frame) })
  assert_eq(first.length(), 1)
  assert_true(first[0].contains("startup context warning"))
  assert_true(first[0].contains("config.warning"))
  hub.native_warning("session-a", "later warning")
  assert_eq(first.length(), 2)
  hub.detach()
  let second : Array[String] = []
  hub.attach(fn(frame) { second.push(frame) })
  assert_eq(second.length(), 0)
  hub.native_warning("session-a", "current warning")
  assert_eq(second.length(), 1)
  assert_true(second[0].contains("current warning"))
}

///|
test "shared console attachment does not replay historical warning frames" {
  let hub = EventHub::new()
  hub.emit("", "", "config.warning", extra=[("reason", "legacy warning")])
  let frames : Array[String] = []
  hub.attach(fn(frame) { frames.push(frame) })
  assert_eq(frames.length(), 0)
}
