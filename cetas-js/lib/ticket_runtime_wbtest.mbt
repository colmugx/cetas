///|
async test "ticket question waits for a Board answer" {
  @async.with_task_group(group => {
    let questions = TicketQuestions::TicketQuestions()
    let waiter = group.spawn(async fn() {
      let answer : Result[@posoco.UiResponse, @askquestion.QuestionError] = Ok(
        questions.ask(
          "task-1",
          "call-1",
          @posoco.UiRequest::Input(prompt="Which path?", default=None),
        ),
      ) catch {
        error => Err(error)
      }
      answer
    })
    @async.sleep(10)
    assert_true(
      questions.answer(
        "ticket-question-1",
        @posoco.UiResponse::Text("the safe path"),
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
  assert_true(questions.answer("missing", @posoco.UiResponse::Yes) is Err(_))
}
