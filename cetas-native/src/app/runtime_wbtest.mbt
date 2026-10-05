///|
test "runtime scene renders focused UiRequest and only live transcript" {
  let shell = NativeShell::new()
  ignore(shell.append_user("finalized user"))
  shell.begin_turn()
  shell.append_text("stream")

  let ui = NativeUiPort::new()
  let response : @aqueue.Queue[@posoco.UiResponse] = Queue(kind=Unbounded)
  let pending = PendingUiRequest::{
    id: 1,
    request: @posoco.UiRequest::Select(
      prompt="Choose mode",
      options=["fast", "safe"],
      default=Some(1),
    ),
    response,
    resolved: false,
  }
  assert_true(ui.requests.try_put(pending))

  let router = NativeInputRouter::new(NativeUiController::new(ui))
  assert_true(router.pump_ui())
  let editor = @ui.EditorModel::new()
  editor.set_text("draft")
  let rewind = @ui.RewindPickerModel::new()
  let scene = build_runtime_scene(
    shell,
    router,
    editor,
    rewind,
    AutocompletePopupModel::new(),
    40U, 8U)
  let text = @utf8.decode(scene.text)

  // Finalized user text belongs to scrollback and must not be repainted.
  assert_false(text.contains("finalized user"))
  assert_true(text.contains("stream"))
  assert_true(text.contains("Choose mode"))
  assert_true(text.contains("fast\nsafe"))
  assert_true(text.contains("> draft"))
  // The selected prefix/highlight is Ratatui-owned now. The list command is
  // kind 5 and encodes selected index 1 as one-based flag 2.
  assert_eq(scene.words[24], 5U)
  assert_eq(scene.words[31], 2U)
}

///|
test "runtime scene lowers idle status without transcript duplication" {
  let shell = NativeShell::new()
  let ui = NativeUiPort::new()
  let router = NativeInputRouter::new(NativeUiController::new(ui))
  let editor = @ui.EditorModel::new()
  let rewind = @ui.RewindPickerModel::new()
  let scene = build_runtime_scene(
    shell,
    router,
    editor,
    rewind,
    AutocompletePopupModel::new(),
    40U, 3U)
  assert_eq(scene.words.length(), 32)
  let text = @utf8.decode(scene.text)
  assert_true(text.contains("> "))
  assert_true(text.contains("· idle"))
}

///|
test "runtime scene gives active rewind picker editor precedence" {
  let shell = NativeShell::new()
  let ui = NativeUiPort::new()
  let router = NativeInputRouter::new(NativeUiController::new(ui))
  let editor = @ui.EditorModel::new()
  editor.set_text("draft")
  let rewind = @ui.RewindPickerModel::new()
  assert_true(
    rewind.open([
      { message_index: 1, preview: "first prompt", },
      { message_index: 4, preview: "second prompt", },
    ]),
  )

  let scene = build_runtime_scene(
    shell,
    router,
    editor,
    rewind,
    AutocompletePopupModel::new(),
    40U, 6U)
  let text = @utf8.decode(scene.text)
  assert_true(text.contains("Rewind to:"))
  assert_true(text.contains("first prompt  message #1"))
  assert_true(text.contains("second prompt  message #4"))
  assert_false(text.contains("> draft"))
  // First rewind point is selected; Ratatui adds the visual marker.
  assert_eq(scene.words[16], 5U)
  assert_eq(scene.words[23], 1U)
}


///|
test "normal query answer layout reserves bottom rows for editor and status" {
  let shell = NativeShell::new()
  shell.begin_turn()
  shell.append_text(
    "a long streaming answer that ratatui may wrap across several terminal rows",
  )
  let ui = NativeUiPort::new()
  let router = NativeInputRouter::new(NativeUiController::new(ui))
  let editor = @ui.EditorModel::new()
  editor.set_text("next question")
  let rewind = @ui.RewindPickerModel::new()

  let scene = build_runtime_scene(
    shell,
    router,
    editor,
    rewind,
    AutocompletePopupModel::new(),
    20U, 8U)
  let text = @utf8.decode(scene.text)
  assert_true(text.contains("a long streaming answer"))
  assert_true(text.contains("> next question"))
  assert_true(text.contains("· responding"))

  // clear, live Markdown paragraph, editor paragraph, cursor, status paragraph.
  assert_eq(scene.words.length(), 40)
  // Live assistant Markdown owns rows 0..5, editor is anchored at row 6,
  // and the status row remains fixed at row 7.
  assert_eq(scene.words[8], 6U)
  assert_eq(scene.words[10], 0U)
  assert_eq(scene.words[12], 6U)
  assert_eq(scene.words[18], 6U)
  assert_eq(scene.words[34], 7U)
}


///|
test "runtime scene reserves a Ratatui List above the editor for autocomplete" {
  let shell = NativeShell::new()
  shell.begin_turn()
  shell.append_text("streaming")
  let ui = NativeUiPort::new()
  let router = NativeInputRouter::new(NativeUiController::new(ui))
  let editor = @ui.EditorModel::new()
  editor.set_text("/he")
  let rewind = @ui.RewindPickerModel::new()
  let popup = AutocompletePopupModel::new()
  assert_true(
    popup.open(
      "/he",
      [
        { value: "/help", label: "/help", description: "Help", },
        { value: "/handoff", label: "/handoff", description: "Handoff", },
      ],
    ),
  )

  let scene = build_runtime_scene(shell, router, editor, rewind, popup, 32U, 8U)
  let text = @utf8.decode(scene.text)
  assert_true(text.contains("streaming"))
  assert_true(text.contains("/help  Help\n/handoff  Handoff"))
  assert_true(text.contains("> /he"))
  assert_true(text.contains("· responding"))

  // clear, live Markdown, List, editor, cursor, status.
  assert_eq(scene.words.length(), 48)
  assert_eq(scene.words[16], 5U)
  assert_eq(scene.words[23], 1U)
}
