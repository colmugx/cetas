///|
/// run_resume drives the Agent's resume_turn entry: a persisted transcript
/// ending with a user message is replayed as the model input without a
/// duplicate, and the final assistant text returns through the same
/// projection as run_prompt (trailing newline per text block).
async test "run_resume replays a trailing user message and returns assistant text" {
  let model = @tk.ScriptedModel([
    @tk.ScriptedModelStep::Respond(@tk.tk_stop_response("resumed answer")),
  ])
  let store = @tk.RecordingSessionPort::RecordingSessionPort()
  store.seed("s1", {
    messages: [@tk.tk_user_msg("task one")],
    metadata: Map::from_array([]),
  })
  let agent = @posoco.Agent(
    exts=[
      @tk.tk_ext(id="model", model=Some(model)),
      @tk.tk_ext(id="io", sessions=[store]),
    ],
    config=@tk.tk_config(),
    events=@posoco.EventSystem(),
  )
  let text = run_resume(agent, "s1")
  inspect(text, content="resumed answer\n")
  // Exactly one model call, and its input carries the replayed user message
  // once — resume must not append the continuation next to a trailing user
  // message.
  assert_eq(model.received_messages.length(), 1)
  let user_count = model.received_messages[0].fold(init=0, fn(acc, message) {
    match message {
      @posoco.Message::UserMessage(content~) =>
        match content {
          [@posoco.Content::Text("task one"), ..] => acc + 1
          _ => acc
        }
      _ => acc
    }
  })
  assert_eq(user_count, 1)
}

///|
/// When the persisted transcript does not end with a user message (the
/// interruption happened mid-tool-loop), resume appends the fixed
/// continuation instead of replaying an assistant message as input.
async test "run_resume appends the continuation for a non-user transcript tail" {
  let model = @tk.ScriptedModel([
    @tk.ScriptedModelStep::Respond(@tk.tk_stop_response("continued")),
  ])
  let store = @tk.RecordingSessionPort::RecordingSessionPort()
  store.seed("s2", {
    messages: [
      @tk.tk_user_msg("task two"),
      @posoco.Message::AssistantMessage(
        content=[@posoco.Content::Text("partial")],
        tool_calls=[],
        reasoning=None,
        finish_reason=@posoco.FinishReason::Stop,
      ),
    ],
    metadata: Map::from_array([]),
  })
  let agent = @posoco.Agent(
    exts=[
      @tk.tk_ext(id="model", model=Some(model)),
      @tk.tk_ext(id="io", sessions=[store]),
    ],
    config=@tk.tk_config(),
    events=@posoco.EventSystem(),
  )
  let text = run_resume(agent, "s2")
  inspect(text, content="continued\n")
  let continuation_count = model.received_messages[0].fold(init=0, fn(
    acc,
    message,
  ) {
    match message {
      @posoco.Message::UserMessage(content~) =>
        match content {
          [@posoco.Content::Text("continue"), ..] => acc + 1
          _ => acc
        }
      _ => acc
    }
  })
  assert_eq(continuation_count, 1)
}
