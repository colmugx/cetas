///|
test "cetas base prompt is minimal and workspace-specific" {
  let prompt = cetas_base_system_prompt("/workspace")
  assert_true(prompt.contains("You are Cetas"))
  assert_true(prompt.contains("Working directory: /workspace"))
}

///|
test "cetas rejects an empty cwd" {
  try {
    let _ = cetas_base_system_prompt("   ")
    fail("expected empty cwd to be rejected")
  } catch {
    @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
      assert_true(detail.contains("cwd"))
    _ => fail("expected ManifestSchemaError for empty cwd")
  }
}

///|
test "every default coding feature contributes prompt instructions" {
  let (_, contributors) = build_default_features()
  assert_true(contributors.length() >= 1)
  let sections : Array[@posoco.SystemPromptSection] = contributors.map(
    fn(c) {
      @posoco.SystemPromptSection::SystemPromptSection(
        id="contributor",
        contributor=c,
      )
    },
  )
  let hook = @posoco.SystemPromptHook::SystemPromptHook(
    base_prompt=cetas_base_system_prompt("/workspace"),
    contributors=sections,
  )
  let prompt = hook.assemble()
  // Each ext's system_prompt() fragment must survive into the composed prompt.
  assert_true(prompt.contains("read"))
  assert_true(prompt.contains("edit"))
  assert_true(prompt.contains("bash"))
}
