///|
test "a minted session id is exactly what resume accepts" {
  let id = mint_memoh_session_id()
  assert_true(id.has_prefix("cetas-memoh-"))
  match validate_resume_session_id(id) {
    Ok(_) => ()
    Err(reason) => fail("minted id rejected: " + reason)
  }
}

///|
test "same-millisecond successors stay distinct and resumable" {
  let first = mint_memoh_session_id()
  let second = mint_memoh_session_id()
  assert_true(first != second)
  assert_true(validate_resume_session_id(first) is Ok(_))
  assert_true(validate_resume_session_id(second) is Ok(_))
}

///|
test "resume rejects ids this runtime never minted" {
  // Memoh stores whatever `session/new` answered, so a foreign id means the
  // host is replaying another agent's state; creating a session for it would
  // silently paper over that.
  for foreign in ["", "sess_abc", "cetas-memoh", "other-memoh-123"] {
    match validate_resume_session_id(foreign) {
      Ok(_) => fail("foreign id accepted: " + foreign)
      Err(_) => ()
    }
  }
}

///|
test "resume accepts a stored id shape after a process restart" {
  match validate_resume_session_id("cetas-memoh-1767225600000-3") {
    Ok(_) => ()
    Err(reason) => fail("stored id rejected: " + reason)
  }
}
