///|
test "native editor input preserves interactive editing and history boundaries" {
  let editor = @ui.EditorModel::new()

  assert_true(
    handle_editor_key(
      editor,
      validation_key(1U, 104U, 0U, 1U),
    ) == EditorChanged,
  )
  assert_true(
    handle_editor_key(
      editor,
      validation_key(1U, 105U, 0U, 1U),
    ) == EditorChanged,
  )
  assert_eq(editor.text(), "hi")

  assert_true(
    handle_editor_key(
      editor,
      validation_key(2U, 0U, @ui.modifier_shift(), 1U),
    ) == EditorChanged,
  )
  assert_eq(editor.text(), "hi\n")

  ignore(handle_editor_paste(editor, "there"))
  match handle_editor_key(editor, validation_key(2U, 0U, 0U, 1U)) {
    EditorSubmit(text) => assert_eq(text, "hi\nthere")
    _ => fail("plain Enter must submit the current editor text")
  }

  editor.set_submit_disabled(true)
  assert_true(
    handle_editor_key(
      editor,
      validation_key(2U, 0U, 0U, 1U),
    ) == EditorUnchanged,
  )
  editor.set_submit_disabled(false)

  editor.record_history("first")
  editor.record_history("second")
  editor.set_text("draft")
  assert_true(
    handle_editor_key(
      editor,
      validation_key(9U, 0U, 0U, 1U),
    ) == EditorChanged,
  )
  assert_eq(editor.text(), "second")
  assert_true(
    handle_editor_key(
      editor,
      validation_key(10U, 0U, 0U, 1U),
    ) == EditorChanged,
  )
  assert_eq(editor.text(), "draft")

  // Kitty release events are ignored at the editor boundary.
  assert_true(
    handle_editor_key(
      editor,
      validation_key(1U, 120U, 0U, 3U),
    ) == EditorUnchanged,
  )
  assert_eq(editor.text(), "draft")
}

///|
test "native editor completion replaces slash and path prefixes" {
  let editor = @ui.EditorModel::new()
  let sources : Array[@ui.AutocompleteSourceSpec] = [
    { trigger: "/", span_spaces: false },
    { trigger: "@", span_spaces: false },
    { trigger: "/model ", span_spaces: true },
  ]

  editor.set_text("/mo")
  assert_true(
    handle_editor_key(
      editor,
      validation_key(5U, 0U, 0U, 1U),
    ) == EditorComplete,
  )
  let slash = @ui.active_autocomplete_matches(
    editor.text_before_cursor(),
    sources,
  )
  assert_eq(slash.length(), 1)
  assert_eq(slash[0].replacement_prefix, "/mo")
  assert_true(editor.apply_completion(
    slash[0].replacement_prefix,
    "/model ",
  ))
  assert_eq(editor.text(), "/model ")

  editor.set_text("open @src/ui")
  assert_true(
    handle_editor_key(
      editor,
      validation_key(5U, 0U, 0U, 1U),
    ) == EditorComplete,
  )
  let path = @ui.active_autocomplete_matches(
    editor.text_before_cursor(),
    sources,
  )
  assert_eq(path.length(), 1)
  assert_eq(path[0].query, "src/ui")
  assert_true(editor.apply_completion(
    path[0].replacement_prefix,
    "@src/ui/editor.mbt",
  ))
  assert_eq(editor.text(), "open @src/ui/editor.mbt")

  editor.set_text("abc@src")
  assert_true(
    @ui.active_autocomplete_matches(
      editor.text_before_cursor(),
      sources,
    ).is_empty(),
  )
}
