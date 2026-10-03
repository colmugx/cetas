///|
fn rewind_test_user(text : String) -> @posoco.Message {
  @posoco.Message::UserMessage(content=[@posoco.Content::Text(text)])
}

///|
async test "rewind_session delegates to SessionStore truncate semantics" {
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  store.seed("s1", {
    messages: [
      rewind_test_user("one"),
      rewind_test_user("two"),
      rewind_test_user("three"),
    ],
    metadata: Map::from_array([("marker", Json::string("kept"))]),
  })

  rewind_session(store as &@posoco.SessionStore, "s1", 2)
  let session = store.load("s1")
  assert_eq(session.messages.length(), 2)
  assert_true(session.messages[0] == rewind_test_user("one"))
  assert_true(session.messages[1] == rewind_test_user("two"))
  assert_true(session.metadata["marker"] == Json::string("kept"))

  // The underlying SessionStore contract clamps out-of-range indexes.
  rewind_session(store as &@posoco.SessionStore, "s1", 99)
  let clamped = store.load("s1")
  assert_eq(clamped.messages.length(), 2)
}
