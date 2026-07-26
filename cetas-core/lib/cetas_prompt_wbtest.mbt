///|
priv struct EmptyPromptContributor {}

///|
impl @posoco.SystemPromptContributor for EmptyPromptContributor with fn system_prompt(
  _self,
) -> String {
  ""
}

///|
test "cetas base prompt is minimal and workspace-specific" {
  let prompt = cetas_base_system_prompt("/workspace")
  assert_true(prompt.contains("You are Cetas"))
  assert_true(prompt.contains("Working directory: /workspace"))
}

///|
test "cetas rejects a feature contributor without prompt instructions" {
  let empty = EmptyPromptContributor::{  }
  try
    ignore(@posoco.SystemPromptHook::new(cetas_base_system_prompt("/workspace"), [empty]))
  catch {
    @posoco.CompositionError::InvalidSystemPrompt(message) =>
      assert_eq(
        message,
        "system prompt contributor at index 0 returned an empty string",
      )
    _ => fail("expected InvalidSystemPrompt")
  } noraise {
    _ => fail("expected empty contributor to fail")
  }
}

///|
test "every default coding feature contributes prompt instructions" {
  let (tools, contributors) = build_default_features()
  assert_eq(tools.length(), 6)
  assert_eq(contributors.length(), 6)
  let hook = @posoco.SystemPromptHook::new(
    cetas_base_system_prompt("/workspace"),
    contributors,
  )
  let prompt = hook.prompt()
  // Each ext's system_prompt() fragment must survive into the composed prompt.
  assert_true(prompt.contains("read"))
  assert_true(prompt.contains("edit"))
  assert_true(prompt.contains("bash"))
}
