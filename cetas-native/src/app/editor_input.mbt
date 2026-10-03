/// Main prompt-editor input reducer.
///
/// Shell-global chords (ctrl+c, ESC, ctrl+t, ctrl+o) are handled before this
/// reducer. This layer mirrors the core pi-tui Editor contract needed by the
/// native app loop: Enter submits; Shift/Ctrl/Alt+Enter and Ctrl+J insert a
/// newline; arrows/home/end edit; Up/Down browse history at the vertical
/// boundary; Tab requests completion.

///|
pub(all) enum EditorInputAction {
  EditorUnchanged
  EditorChanged
  EditorSubmit(String)
  EditorComplete
} derive(Eq)

///|
pub extend EditorInputAction with Eq::{equal, not_equal}

///|
fn editor_text_char(event : @ui.TerminalEvent) -> String? {
  guard event.key_code_value() is @ui.KeyChar(codepoint) else { return None }
  let non_text_modifiers = @ui.modifier_control() |
    @ui.modifier_alt() |
    @ui.modifier_super() |
    @ui.modifier_hyper() |
    @ui.modifier_meta()
  if (event.modifiers & non_text_modifiers) != 0U {
    return None
  }
  match codepoint.reinterpret_as_int().to_char() {
    Some(ch) => Some(ch.to_string())
    None => None
  }
}

///|
pub fn handle_editor_key(
  editor : @ui.EditorModel,
  event : @ui.TerminalEvent,
) -> EditorInputAction {
  if !event.is_actionable_key() {
    return EditorUnchanged
  }

  if event.matches_key(@ui.KeyEnter, 0U) {
    if !editor.can_submit() {
      return EditorUnchanged
    }
    return EditorSubmit(editor.text())
  }

  if event.matches_key(@ui.KeyEnter, @ui.modifier_shift()) ||
    event.matches_key(@ui.KeyEnter, @ui.modifier_control()) ||
    event.matches_key(@ui.KeyEnter, @ui.modifier_alt()) ||
    event.matches_char(106U, @ui.modifier_control()) {
    editor.insert_newline()
    return EditorChanged
  }

  if event.matches_key(@ui.KeyTab, 0U) {
    return EditorComplete
  }

  if event.matches_key(@ui.KeyBackspace, 0U) {
    editor.backspace()
    return EditorChanged
  }
  if event.matches_key(@ui.KeyDelete, 0U) ||
    event.matches_char(100U, @ui.modifier_control()) {
    editor.delete_forward()
    return EditorChanged
  }

  if event.matches_key(@ui.KeyLeft, 0U) ||
    event.matches_char(98U, @ui.modifier_control()) {
    editor.move_left()
    return EditorChanged
  }
  if event.matches_key(@ui.KeyRight, 0U) ||
    event.matches_char(102U, @ui.modifier_control()) {
    editor.move_right()
    return EditorChanged
  }

  if event.matches_key(@ui.KeyHome, 0U) ||
    event.matches_key(@ui.KeyHome, @ui.modifier_control()) ||
    event.matches_char(97U, @ui.modifier_control()) {
    editor.move_home()
    return EditorChanged
  }
  if event.matches_key(@ui.KeyEnd, 0U) ||
    event.matches_key(@ui.KeyEnd, @ui.modifier_control()) ||
    event.matches_char(101U, @ui.modifier_control()) {
    editor.move_end()
    return EditorChanged
  }

  if event.matches_key(@ui.KeyUp, 0U) {
    let cursor = editor.cursor()
    if cursor.line == 0 {
      ignore(editor.history_previous())
    } else {
      editor.move_up()
    }
    return EditorChanged
  }
  if event.matches_key(@ui.KeyDown, 0U) {
    let cursor = editor.cursor()
    if cursor.line + 1 >= editor.line_count() {
      ignore(editor.history_next())
    } else {
      editor.move_down()
    }
    return EditorChanged
  }

  match editor_text_char(event) {
    Some(text) => {
      editor.insert_text(text)
      EditorChanged
    }
    None => EditorUnchanged
  }
}

///|
pub fn handle_editor_paste(
  editor : @ui.EditorModel,
  text : String,
) -> EditorInputAction {
  if text.is_empty() {
    EditorUnchanged
  } else {
    editor.insert_text(text)
    EditorChanged
  }
}

///|
pub fn editor_input_validation_marker() -> Int {
  let editor = @ui.EditorModel::new()
  if handle_editor_key(editor, validation_key(1U, 104U, 0U, 1U)) !=
    EditorChanged ||
    editor.text() != "h" {
    return 0
  }

  if handle_editor_key(editor, validation_key(2U, 0U, @ui.modifier_shift(), 1U)) !=
    EditorChanged ||
    editor.text() != "h\n" {
    return 0
  }

  editor.insert_text("there")
  match handle_editor_key(editor, validation_key(2U, 0U, 0U, 1U)) {
    EditorSubmit(text) if text == "h\nthere" => ()
    _ => return 0
  }

  editor.set_submit_disabled(true)
  if handle_editor_key(editor, validation_key(2U, 0U, 0U, 1U)) !=
    EditorUnchanged {
    return 0
  }
  editor.set_submit_disabled(false)

  editor.record_history("first")
  editor.record_history("second")
  editor.clear()
  ignore(handle_editor_key(editor, validation_key(9U, 0U, 0U, 1U)))
  if editor.text() != "second" {
    return 0
  }

  if handle_editor_key(editor, validation_key(5U, 0U, 0U, 1U)) != EditorComplete {
    return 0
  }

  1
}
