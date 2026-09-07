///|
/// peer_wbtest.mbt — the herdr peer envelope parser: exact-match acceptance
/// and malformed-line rejection (plain lines must pass through untouched).

///|
test "peer envelope parses from, session, and task" {
  let env = match
    parse_peer_envelope(
      "[cetas-peer from=pane-9 session=cetas-abc] refactor the loop",
    ) {
    Some(env) => env
    None => fail("well-formed envelope must parse")
  }
  assert_eq(env.from, "pane-9")
  assert_eq(env.session, "cetas-abc")
  assert_eq(env.task, "refactor the loop")
}

///|
test "peer envelope task may itself contain brackets and spaces" {
  let env = match
    parse_peer_envelope(
      "[cetas-peer from=a session=b] run [cetas-headless] twice now",
    ) {
    Some(env) => env
    None => fail("task with brackets must parse")
  }
  assert_eq(env.from, "a")
  assert_eq(env.session, "b")
  assert_eq(env.task, "run [cetas-headless] twice now")
}

///|
test "peer envelope without task text yields an empty task" {
  let env = match parse_peer_envelope("[cetas-peer from=a session=b] ") {
    Some(env) => env
    None => fail("envelope with trailing space must parse")
  }
  assert_eq(env.task, "")
}

///|
test "peer envelope rejects malformed and plain lines" {
  assert_true(parse_peer_envelope("plain task") is None)
  assert_true(parse_peer_envelope("[cetas-peer from= session=b] task") is None)
  assert_true(parse_peer_envelope("[cetas-peer from=a session=] task") is None)
  assert_true(parse_peer_envelope("[cetas-peer from=a] task") is None)
  assert_true(parse_peer_envelope("[cetas-peer from=a session=b") is None)
  assert_true(parse_peer_envelope("[cetas-peer from=a session=b]") is None)
  assert_true(parse_peer_envelope("[other from=a session=b] task") is None)
  assert_true(parse_peer_envelope("") is None)
}
