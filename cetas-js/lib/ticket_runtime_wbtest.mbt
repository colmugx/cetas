///|
test "ticket system prompt carries the Cetas language policy" {
  let prompt = ticket_system_prompt("/workspace", "You are a test role.")
  assert_true(prompt.contains("same language as the user's current message"))
  assert_true(prompt.contains("Language override for this Board ticket"))
  assert_true(prompt.contains("ticket title/description"))
}

///|
async test "ticket question waits for a Board answer" {
  @async.with_task_group(group => {
    let questions = TicketQuestions::TicketQuestions()
    let waiter = group.spawn(async fn() {
      let answer : Result[@posoco.UiResponse, @askquestion.QuestionError] = Ok(
        questions.ask(
          "task-1",
          "call-1",
          "worker",
          "product_owner",
          @posoco.UiRequest::Input(prompt="Which path?", default=None),
        ),
      ) catch {
        error => Err(error)
      }
      answer
    })
    @async.sleep(10)
    let open = questions.questions.get("ticket-question-1").unwrap()
    assert_eq(open.asked_by, "worker")
    assert_eq(open.audience, "product_owner")
    assert_eq(open.status, "open")
    assert_true(
      questions.answer(
        "ticket-question-1",
        @posoco.UiResponse::Text("the safe path"),
        "product_owner",
      )
      is Ok(_),
    )
    let answer = waiter.wait()
    match answer {
      Ok(@posoco.UiResponse::Text(value)) => assert_eq(value, "the safe path")
      _ => fail("expected the answered text")
    }
  })
}

///|
test "unknown ticket question answers are rejected" {
  let questions = TicketQuestions::TicketQuestions()
  assert_true(
    questions.answer("missing", @posoco.UiResponse::Yes, "product_owner")
    is Err(_),
  )
}

///|
test "required roles defaults to all and preserves an RD-only plan" {
  assert_eq(required_roles({}), ["rd", "set", "te"])
  assert_eq(required_roles({ "required_roles": ["rd"] }), ["rd"])
  assert_eq(required_roles({ "required_roles": ["set"] }), ["rd", "set", "te"])
}
