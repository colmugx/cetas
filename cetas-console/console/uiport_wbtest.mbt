///|
/// A cancelled waiter must not retain a live registry entry. Its late reply
/// must not resolve a later waiter with another id.
test "retired UiRequest ids cannot affect subsequent prompts" {
  let registry = UiRegistry::new()
  let (first, _) = registry.register()
  let (second, _) = registry.register()
  assert_true(registry.pending.contains(first))
  assert_true(registry.pending.contains(second))
  registry.forget(first)
  assert_false(registry.pending.contains(first))
  registry.resolve(first, "{\"yes\":true}")
  assert_true(registry.pending.contains(second))
  registry.resolve(second, "{\"cancelled\":true}")
  assert_false(registry.pending.contains(second))
}

///|
/// Shutdown has to wake every still-waiting request, leaving nothing that
/// could be answered by a delayed event from the old terminal.
test "UiRegistry shutdown drains pending requests" {
  let registry = UiRegistry::new()
  let (first, _) = registry.register()
  let (second, _) = registry.register()
  registry.cancel_all()
  assert_false(registry.pending.contains(first))
  assert_false(registry.pending.contains(second))
  registry.cancel_all()
  assert_false(registry.pending.contains(first))
  assert_false(registry.pending.contains(second))
}
