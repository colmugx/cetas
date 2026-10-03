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
  let scene = build_runtime_scene(shell, router, editor, rewind, 40U, 8U)
  let text = @utf8.decode(scene.text)

  // Finalized user text belongs to scrollback and must not be repainted.
  assert_false(text.contains("finalized user"))
  assert_true(text.contains("stream"))
  assert_true(text.contains("Choose mode"))
  assert_true(text.contains("  fast"))
  assert_true(text.contains("> safe"))
  assert_true(text.contains("> draft"))
}

///|
test "runtime scene lowers idle status without transcript duplication" {
  let shell = NativeShell::new()
  let ui = NativeUiPort::new()
  let router = NativeInputRouter::new(NativeUiController::new(ui))
  let editor = @ui.EditorModel::new()
  let rewind = @ui.RewindPickerModel::new()
  let scene = build_runtime_scene(shell, router, editor, rewind, 40U, 3U)
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

  let scene = build_runtime_scene(shell, router, editor, rewind, 40U, 6U)
  let text = @utf8.decode(scene.text)
  assert_true(text.contains("Rewind to:"))
  assert_true(text.contains("> first prompt"))
  assert_true(text.contains("  second prompt"))
  assert_false(text.contains("> draft"))
}
