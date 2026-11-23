///|
test "database rewind skips injected memory but keeps the user prompt" {
  let memory = @kernel.Message::UserMessage(content=[
    @kernel.Content::Text(@posoco.MEMORY_INBOUND_LEAD + "\n\nRecalled text"),
  ])
  let user = @kernel.Message::UserMessage(content=[
    @kernel.Content::Text("Actual user prompt"),
  ])
  assert_eq(database_user_text(memory), None)
  assert_eq(database_user_text(user), Some("Actual user prompt"))
}
