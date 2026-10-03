///|
test "transcript streaming finalization is idempotent" {
  let transcript = TranscriptModel::new()
  transcript.begin_turn()

  transcript.append_reasoning("think-1")
  transcript.append_reasoning("-2")
  transcript.append_text("hello")
  transcript.append_text(" world")

  transcript.message_end("duplicate reasoning", "duplicate text")

  assert_eq(transcript.row_count(), 2)
  assert_true(transcript.row(0).finalized)
  assert_true(transcript.row(1).finalized)
  assert_true(transcript.row(0).kind == TranscriptThinking)
  assert_true(transcript.row(1).kind == TranscriptAssistant)
  assert_eq(transcript.row(1).text, "hello world")
}

///|
test "transcript scrollback boundary only returns finalized rows once" {
  let transcript = TranscriptModel::new()
  ignore(transcript.append_finalized(TranscriptUser, "question"))
  let live = transcript.append_live(TranscriptAssistant, "partial")

  let first = transcript.take_scrollback_ready()
  assert_eq(first.length(), 1)
  assert_eq(first[0].text, "question")

  let second = transcript.take_scrollback_ready()
  assert_true(second.is_empty())

  assert_true(transcript.update_row(live, "partial + more"))
  assert_true(transcript.take_scrollback_ready().is_empty())

  assert_true(transcript.finalize(live))
  let third = transcript.take_scrollback_ready()
  assert_eq(third.length(), 1)
  assert_eq(third[0].text, "partial + more")
}

///|
test "queued user promotion crosses immutable boundary" {
  let transcript = TranscriptModel::new()
  let queued = transcript.append_queued_user("follow up")

  assert_true(transcript.promote_queued_user(queued))
  assert_false(transcript.update_row(queued, "mutated"))
  assert_true(transcript.row(0).kind == TranscriptUser)
  assert_true(transcript.row(0).finalized)
}
