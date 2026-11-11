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
