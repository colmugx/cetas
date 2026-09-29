///|
/// approval_wbtest.mbt — the decided y/a/n/s mapping, the re-prompt loop,
/// and the unattended degradation, over the scripted FakeTty.

///|
async test "approval decision mapping covers the decided table" {
  match approval_decision("y") {
    Some(@permission.AllowOnce) => ()
    _ => fail("y must allow once")
  }
  match approval_decision("1") {
    Some(@permission.AllowOnce) => ()
    _ => fail("1 must allow once")
  }
  match approval_decision("a") {
    Some(@permission.AllowSession) => ()
    _ => fail("a must allow for the session")
  }
  match approval_decision("2") {
    Some(@permission.AllowSession) => ()
    _ => fail("2 must allow for the session")
  }
  match approval_decision("n") {
    Some(@permission.Deny(reason~)) => assert_eq(reason, "denied by user")
    _ => fail("n must deny")
  }
  match approval_decision("3") {
    Some(@permission.Deny(reason~)) => assert_eq(reason, "denied by user")
    _ => fail("3 must deny")
  }
  match approval_decision("") {
    Some(@permission.Deny(reason~)) => assert_eq(reason, "denied by user")
    _ => fail("the bare enter default must deny")
  }
  match approval_decision("s") {
    Some(@permission.Deny(reason~)) => assert_eq(reason, "skipped")
    _ => fail("s must deny as skipped")
  }
  match approval_decision("4") {
    Some(@permission.Deny(reason~)) => assert_eq(reason, "skipped")
    _ => fail("4 must deny as skipped")
  }
  // Whitespace and case are tolerated.
  match approval_decision("  Y ") {
    Some(@permission.AllowOnce) => ()
    _ => fail("trimmed uppercase y must allow once")
  }
  // Anything else re-prompts.
  assert_true(approval_decision("maybe") is None)
}

///|
async test "approval ask renders the decided prompt, re-prompts garbage, and caches on a" {
  let tty = FakeTty::FakeTty(["garbage", "zz", "a"])
  let source = TerminalApprovalSource::TerminalApprovalSource(
    tty=Some(tty.channel()),
  )
  let decision = @permission.ApprovalSource::ask(
    source,
    tk_approval_request(tool_name="write", category="write"),
  )
  match decision {
    @permission.AllowSession => ()
    _ => fail("the scripted a answer must allow for the session")
  }
  // The exact decided prompt format, the two re-prompt hints, three reads.
  assert_eq(
    tty.writes[0],
    "[permission] write (write): {\"path\": \"notes.txt\"} [y]es/[a]lways/[n]o/[s]kip (default n): ",
  )
  assert_eq(tty.writes[1], "unrecognized answer; reply y, a, n, or s\n")
  assert_eq(
    tty.writes[2],
    "[permission] write (write): {\"path\": \"notes.txt\"} [y]es/[a]lways/[n]o/[s]kip (default n): ",
  )
  assert_eq(tty.writes[3], "unrecognized answer; reply y, a, n, or s\n")
  assert_eq(tty.writes.length(), 5)
  assert_eq(tty.cursor, 3)
}

///|
async test "approval ask denies on EOF" {
  let tty = FakeTty::FakeTty([])
  let source = TerminalApprovalSource::TerminalApprovalSource(
    tty=Some(tty.channel()),
  )
  let decision = @permission.ApprovalSource::ask(
    source,
    tk_approval_request(tool_name="bash", category="shell"),
  )
  match decision {
    @permission.Deny(reason~) =>
      assert_eq(reason, "denied: approval input closed")
    _ => fail("EOF must deny")
  }
  let channel = tty.channel()
  (channel.close)()
  assert_true(tty.closed)
}

///|
async test "approval ask without a tty prints the unattended hint and denies" {
  let notices : Array[String] = []
  let source = TerminalApprovalSource::TerminalApprovalSource(tty=None, notice=fn(
    text : String,
  ) {
    notices.push(text)
  })
  let decision = @permission.ApprovalSource::ask(
    source,
    tk_approval_request(tool_name="edit", category="write"),
  )
  match decision {
    @permission.Deny(reason~) =>
      assert_true(reason.contains("unattended, use --yolo"))
    _ => fail("the degraded path must deny")
  }
  assert_eq(notices.length(), 1)
  assert_true(notices[0].contains("unattended, use --yolo"))
  assert_true(notices[0].contains("edit"))
}
