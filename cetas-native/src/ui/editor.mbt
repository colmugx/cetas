/// MoonBit-owned multiline editor state.
///
/// Cursor columns are UTF-16 code-unit offsets, matching MoonBit String
/// indexing and the existing TypeScript autocomplete contract. Terminal cell
/// width is a rendering concern and is deliberately kept out of this reducer.

///|
pub(all) struct EditorCursor {
  line : Int
  column : Int
}

///|
pub struct EditorModel {
  lines : Array[String]
  mut cursor_line : Int
  mut cursor_column : Int
  mut submit_disabled : Bool
  history : Array[String]
  mut history_index : Int?
  mut history_draft : String
}

///|
pub fn EditorModel::new() -> EditorModel {
  {
    lines: [""],
    cursor_line: 0,
    cursor_column: 0,
    submit_disabled: false,
    history: [],
    history_index: None,
    history_draft: "",
  }
}

///|
pub fn EditorModel::cursor(self : EditorModel) -> EditorCursor {
  { line: self.cursor_line, column: self.cursor_column }
}

///|
pub fn EditorModel::line_count(self : EditorModel) -> Int {
  self.lines.length()
}

///|
pub fn EditorModel::current_line(self : EditorModel) -> String {
  self.lines[self.cursor_line]
}

///|
pub fn EditorModel::text(self : EditorModel) -> String {
  self.lines[:].join("\n")
}

///|
pub fn EditorModel::text_before_cursor(self : EditorModel) -> String {
  self.current_line()[:self.cursor_column].to_owned()
}

///|
pub fn EditorModel::set_submit_disabled(
  self : EditorModel,
  disabled : Bool,
) -> Unit {
  self.submit_disabled = disabled
}

///|
pub fn EditorModel::can_submit(self : EditorModel) -> Bool {
  !self.submit_disabled
}

///|
fn EditorModel::leave_history_browse(self : EditorModel) -> Unit {
  self.history_index = None
  self.history_draft = ""
}

///|
/// Record one accepted prompt without coupling history to submission policy.
///
/// Empty prompts are ignored. Consecutive duplicates are collapsed so key
/// repeat or retry paths cannot flood the history with identical entries.
pub fn EditorModel::record_history(
  self : EditorModel,
  text : String,
) -> Unit {
  if text.is_empty() {
    return
  }
  if self.history.length() > 0 &&
    self.history[self.history.length() - 1] == text {
    self.leave_history_browse()
    return
  }
  self.history.push(text)
  self.leave_history_browse()
}

///|
pub fn EditorModel::history_length(self : EditorModel) -> Int {
  self.history.length()
}

///|
/// Browse toward older entries. The first transition snapshots the current
/// draft so moving forward past the newest entry can restore it exactly.
pub fn EditorModel::history_previous(self : EditorModel) -> Bool {
  if self.history.is_empty() {
    return false
  }

  let index = match self.history_index {
    None => {
      self.history_draft = self.text()
      self.history.length() - 1
    }
    Some(value) =>
      if value > 0 {
        value - 1
      } else {
        return false
      }
  }

  self.history_index = Some(index)
  self.set_text_from_history(self.history[index])
  true
}

///|
/// Browse toward newer entries. Moving beyond the newest recorded prompt
/// restores the draft that was present before history browsing began.
pub fn EditorModel::history_next(self : EditorModel) -> Bool {
  guard self.history_index is Some(index) else {
    return false
  }

  if index + 1 < self.history.length() {
    let next = index + 1
    self.history_index = Some(next)
    self.set_text_from_history(self.history[next])
  } else {
    let draft = self.history_draft
    self.history_index = None
    self.history_draft = ""
    self.set_text_from_history(draft)
  }
  true
}

///|
fn EditorModel::set_text_from_history(
  self : EditorModel,
  text : String,
) -> Unit {
  self.lines.clear()
  for line in text.split("\n") {
    self.lines.push(line.to_owned())
  }
  if self.lines.is_empty() {
    self.lines.push("")
  }
  self.cursor_line = self.lines.length() - 1
  self.cursor_column = self.lines[self.cursor_line].length()
}

///|
pub fn EditorModel::clear(self : EditorModel) -> Unit {
  self.leave_history_browse()
  self.lines.clear()
  self.lines.push("")
  self.cursor_line = 0
  self.cursor_column = 0
}

///|
pub fn EditorModel::set_text(
  self : EditorModel,
  text : String,
) -> Unit {
  self.leave_history_browse()
  self.set_text_from_history(text)
}

///|
fn previous_column(line : String, column : Int) -> Int {
  if column <= 0 {
    return 0
  }
  if column >= 2 &&
    line.code_unit_at(column - 1).is_trailing_surrogate() &&
    line.code_unit_at(column - 2).is_leading_surrogate() {
    column - 2
  } else {
    column - 1
  }
}

///|
fn next_column(line : String, column : Int) -> Int {
  if column >= line.length() {
    return line.length()
  }
  if column + 1 < line.length() &&
    line.code_unit_at(column).is_leading_surrogate() &&
    line.code_unit_at(column + 1).is_trailing_surrogate() {
    column + 2
  } else {
    column + 1
  }
}

///|
pub fn EditorModel::move_left(self : EditorModel) -> Unit {
  if self.cursor_column > 0 {
    self.cursor_column = previous_column(self.current_line(), self.cursor_column)
  } else if self.cursor_line > 0 {
    self.cursor_line -= 1
    self.cursor_column = self.current_line().length()
  }
}

///|
pub fn EditorModel::move_right(self : EditorModel) -> Unit {
  let line = self.current_line()
  if self.cursor_column < line.length() {
    self.cursor_column = next_column(line, self.cursor_column)
  } else if self.cursor_line + 1 < self.lines.length() {
    self.cursor_line += 1
    self.cursor_column = 0
  }
}

///|
pub fn EditorModel::move_home(self : EditorModel) -> Unit {
  self.cursor_column = 0
}

///|
pub fn EditorModel::move_end(self : EditorModel) -> Unit {
  self.cursor_column = self.current_line().length()
}

///|
pub fn EditorModel::move_up(self : EditorModel) -> Unit {
  if self.cursor_line <= 0 {
    return
  }
  self.cursor_line -= 1
  self.cursor_column = Int::min(self.cursor_column, self.current_line().length())
}

///|
pub fn EditorModel::move_down(self : EditorModel) -> Unit {
  if self.cursor_line + 1 >= self.lines.length() {
    return
  }
  self.cursor_line += 1
  self.cursor_column = Int::min(self.cursor_column, self.current_line().length())
}

///|
pub fn EditorModel::insert_text(
  self : EditorModel,
  text : String,
) -> Unit {
  self.leave_history_browse()
  if text.is_empty() {
    return
  }

  let current = self.current_line()
  let before = current[:self.cursor_column].to_owned()
  let after = current[self.cursor_column:].to_owned()
  let inserted = text.split("\n").map(part => part.to_owned()).to_array()

  if inserted.length() == 1 {
    let value = before + inserted[0] + after
    self.lines[self.cursor_line] = value
    self.cursor_column += inserted[0].length()
    return
  }

  self.lines[self.cursor_line] = before + inserted[0]
  let mut target_line = self.cursor_line
  for index in 1..<inserted.length() {
    target_line += 1
    let value = if index + 1 == inserted.length() {
      inserted[index] + after
    } else {
      inserted[index]
    }
    self.lines.insert(target_line, value)
  }
  self.cursor_line = target_line
  self.cursor_column = inserted[inserted.length() - 1].length()
}

///|
pub fn EditorModel::insert_newline(self : EditorModel) -> Unit {
  self.insert_text("\n")
}

///|
pub fn EditorModel::backspace(self : EditorModel) -> Unit {
  self.leave_history_browse()
  if self.cursor_column > 0 {
    let line = self.current_line()
    let start = previous_column(line, self.cursor_column)
    self.lines[self.cursor_line] =
      line[:start].to_owned() + line[self.cursor_column:].to_owned()
    self.cursor_column = start
    return
  }

  if self.cursor_line <= 0 {
    return
  }

  let current = self.lines.remove(self.cursor_line)
  self.cursor_line -= 1
  let previous = self.current_line()
  self.cursor_column = previous.length()
  self.lines[self.cursor_line] = previous + current
}

///|
pub fn EditorModel::delete_forward(self : EditorModel) -> Unit {
  self.leave_history_browse()
  let line = self.current_line()
  if self.cursor_column < line.length() {
    let end = next_column(line, self.cursor_column)
    self.lines[self.cursor_line] =
      line[:self.cursor_column].to_owned() + line[end:].to_owned()
    return
  }

  if self.cursor_line + 1 >= self.lines.length() {
    return
  }

  let next = self.lines.remove(self.cursor_line + 1)
  self.lines[self.cursor_line] = line + next
}

///|
pub fn EditorModel::replace_current_line_range(
  self : EditorModel,
  start : Int,
  end : Int,
  replacement : String,
) -> Bool {
  self.leave_history_browse()
  let line = self.current_line()
  if start < 0 || end < start || end > line.length() || replacement.contains("\n") {
    return false
  }

  self.lines[self.cursor_line] =
    line[:start].to_owned() + replacement + line[end:].to_owned()
  self.cursor_column = start + replacement.length()
  true
}

///|
pub(all) struct AutocompleteSourceSpec {
  trigger : String
  span_spaces : Bool
}

///|
pub(all) struct AutocompleteMatch {
  source_index : Int
  trigger_index : Int
  query : String
  replacement_prefix : String
}

///|
fn autocomplete_token_boundary(text : String, index : Int) -> Bool {
  if index == 0 {
    return true
  }
  match text.code_unit_at(index - 1).to_char() {
    Some(ch) => ch.is_whitespace()
    None => false
  }
}

///|
fn active_autocomplete_match(
  text_before_cursor : String,
  source_index : Int,
  source : AutocompleteSourceSpec,
) -> AutocompleteMatch? {
  guard text_before_cursor.rev_find(source.trigger) is Some(trigger_index) else {
    return None
  }
  if !autocomplete_token_boundary(text_before_cursor, trigger_index) {
    return None
  }

  let replacement_prefix = text_before_cursor[trigger_index:].to_owned()
  let query_view = replacement_prefix[source.trigger.length():]
  if !source.span_spaces && query_view.any(ch => ch.is_whitespace()) {
    return None
  }

  Some({
    source_index,
    trigger_index,
    query: query_view.to_owned(),
    replacement_prefix,
  })
}

///|
/// Return every source participating in the winning completion request.
///
/// This mirrors cetas-js UiRegistry:
/// - source trigger must start at a token boundary;
/// - non-span sources stop matching once their query contains whitespace;
/// - longest replacement prefix wins;
/// - equal-length prefixes prefer the trigger closest to the cursor;
/// - sources producing exactly the same winning replacement prefix co-exist.
pub fn active_autocomplete_matches(
  text_before_cursor : String,
  sources : Array[AutocompleteSourceSpec],
) -> Array[AutocompleteMatch] {
  let matches : Array[AutocompleteMatch] = []
  for source_index, source in sources {
    match active_autocomplete_match(text_before_cursor, source_index, source) {
      Some(value) => matches.push(value)
      None => ()
    }
  }

  if matches.is_empty() {
    return []
  }

  let mut winner = matches[0]
  for candidate in matches {
    if candidate.replacement_prefix.length() > winner.replacement_prefix.length() ||
      (candidate.replacement_prefix.length() == winner.replacement_prefix.length() &&
        candidate.trigger_index > winner.trigger_index) {
      winner = candidate
    }
  }

  matches.filter(
    candidate => candidate.replacement_prefix == winner.replacement_prefix,
  )
}

///|
pub fn EditorModel::apply_completion(
  self : EditorModel,
  prefix : String,
  replacement : String,
) -> Bool {
  let line = self.current_line()
  let start = self.cursor_column - prefix.length()
  if start < 0 ||
    line[start:self.cursor_column].to_owned() != prefix ||
    replacement.contains("\n") {
    return false
  }
  self.replace_current_line_range(start, self.cursor_column, replacement)
}

///|
pub fn editor_validation_marker() -> Int {
  let editor = EditorModel::new()
  editor.insert_text("hello")
  editor.move_left()
  editor.backspace()
  if editor.text() != "helo" || editor.cursor().column != 3 {
    return 0
  }

  editor.move_end()
  editor.insert_text("\nworld")
  editor.move_home()
  editor.delete_forward()
  if editor.text() != "helo\norld" {
    return 0
  }

  editor.set_text("a🤣b")
  editor.move_left()
  editor.backspace()
  if editor.text() != "ab" {
    return 0
  }

  if !editor.replace_current_line_range(1, 2, "Z") ||
    editor.text() != "aZ" ||
    editor.cursor().column != 2 {
    return 0
  }

  editor.record_history("first")
  editor.record_history("second")
  editor.record_history("second")
  editor.set_text("draft")
  if editor.history_length() != 2 ||
    !editor.history_previous() ||
    editor.text() != "second" ||
    !editor.history_previous() ||
    editor.text() != "first" ||
    editor.history_previous() {
    return 0
  }
  if !editor.history_next() ||
    editor.text() != "second" ||
    !editor.history_next() ||
    editor.text() != "draft" ||
    editor.history_next() {
    return 0
  }
  editor.history_previous() |> ignore
  editor.insert_text("!")
  if editor.text() != "second!" || editor.history_next() {
    return 0
  }

  let sources : Array[AutocompleteSourceSpec] = [
    { trigger: "/", span_spaces: false },
    { trigger: "@", span_spaces: false },
    { trigger: "/model ", span_spaces: true },
    { trigger: "/model ", span_spaces: true },
  ]

  let model_matches = active_autocomplete_matches("/model gpt", sources)
  if model_matches.length() != 2 ||
    model_matches[0].query != "gpt" ||
    model_matches[0].replacement_prefix != "/model gpt" {
    return 0
  }

  if !active_autocomplete_matches("abc@src", sources).is_empty() {
    return 0
  }

  let file_matches = active_autocomplete_matches("open @src/ui", sources)
  if file_matches.length() != 1 ||
    file_matches[0].query != "src/ui" ||
    file_matches[0].trigger_index != 5 {
    return 0
  }

  editor.set_text("/mo")
  let completion = active_autocomplete_matches(editor.text_before_cursor(), sources)
  if completion.length() != 1 ||
    !editor.apply_completion(completion[0].replacement_prefix, "/model ") ||
    editor.text() != "/model " {
    return 0
  }

  1
}
