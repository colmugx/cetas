// run_prompt: the `images~` parameter must land as Image blocks appended
// after the prompt Text block, so hosts can attach `@path`-resolved images
// without any host-side message surgery.

///|
fn run_prompt_test_agent(
  model : @posoco.ScriptedModel,
  store : @posoco.RecordingSessionStore,
) -> @posoco.Agent raise {
  @posoco.Agent(
    exts=[
      @posoco.ManifestOnly::ManifestOnly({
        id: "model",
        models: [model as &@posoco.ModelPort],
        tools: [],
        sessions: [store as &@posoco.SessionStore],
        observers: [],
        hooks: [],
        memory: [],
        lifecycle: [],
        commands: [],
        ui: [],
        prompt_contributors: [],
        requires: [],
      }),
    ],
    config={
      max_tool_rounds: Some(2),
      system_prompt: None,
      temperature: None,
      max_output_tokens: None,
      model_context_window: None,
      compact_threshold: None,
    },
  )
}

///|
async test "run_prompt appends image blocks after the prompt text" {
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("ok")),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let agent = run_prompt_test_agent(model, store)
  let image : @posoco.Content = @posoco.Content::Image(
    media_type="image/png",
    data="aW1hZ2UtYnl0ZXM=",
  )
  let reply = run_prompt(agent, "what is @shot.png", "s1", images=[image])
  inspect(reply, content="ok\n")
  assert_true(model.received_messages.length() > 0)
  let msgs = model.received_messages[0]
  let mut user_seen = false
  for msg in msgs {
    match msg {
      @posoco.Message::UserMessage(content~) => {
        user_seen = true
        match content {
          [@posoco.Content::Text(t), @posoco.Content::Image(media_type~, data~)] => {
            inspect(t, content="what is @shot.png")
            inspect(media_type, content="image/png")
            inspect(data, content="aW1hZ2UtYnl0ZXM=")
          }
          _ => fail("user message should be [Text, Image]")
        }
      }
      _ => ()
    }
  }
  assert_true(user_seen)
}
