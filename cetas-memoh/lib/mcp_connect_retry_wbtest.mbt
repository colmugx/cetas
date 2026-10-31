///|
/// The retry schedule and the attempt count are two halves of one budget; a
/// mismatch would index past the array, and an oversized budget would make
/// session creation feel hung on a dead gateway.
test "the tool-connect retry budget stays small and self-consistent" {
  assert_eq(
    memoh_tools_connect_backoff_ms.length(),
    MEMOH_TOOLS_CONNECT_ATTEMPTS - 1,
  )
  let mut total = 0
  for delay in memoh_tools_connect_backoff_ms {
    assert_true(delay > 0)
    total += delay
  }
  // Memoh waits up to five seconds for its own route registration; staying
  // comfortably under that keeps a broken gateway from stalling a turn.
  assert_true(total < 5000)
}
