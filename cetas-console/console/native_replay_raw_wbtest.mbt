///|
/// A Raw projection is never a transport frame. Its item count, not a throwaway
/// serialization of a potentially giant body, must stop the single-item scan.
test "raw replay projection does not charge the wire page budget" {
  let projector = NativeReplayProjector::new(0, 1, 1, Raw, 0)
  projector.add_text("assistant", "r-1", "完整正文 **markdown**")
  assert_eq(projector.items.length(), 1)
  assert_eq(projector.full, true)
  assert_eq(projector.bytes, 0)
  assert_eq(
    replay_test_string(projector.items[0], "text"),
    "完整正文 **markdown**",
  )
}
