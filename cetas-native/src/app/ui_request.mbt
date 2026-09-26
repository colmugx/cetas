/// Terminal-facing presentation state for one Posoco UiRequest.
///
/// This reducer is intentionally separate from NativeUiPort's rendezvous
/// transport. The terminal loop owns focus and rendering; this model only
/// maps normalized input/paste into deterministic UiResponse values.

///|
pub(all) enum UiRequestPanelKind {
  UiPanelInput
  UiPanelConfirm
  UiPanelSelect
} derive(Eq)

///|
pub extend UiRequestPanelKind with Eq::{equal, not_equal}

///|
pub struct UiRequestPanelModel {
  kind : UiRequestPanelKind
  prompt : String
  editor : @ui.EditorModel
  list : @ui.SelectListModel
}

///|
fn ui_request_items(options : Array[String]) -> Array[@ui.SelectItem] {
  let items : Array[@ui.SelectItem] = []
  for index, option in options {
    items.push({
      value: index.to_string(),
      label: option,
      description: "",
    })
  }
  items
}

///|
pub fn UiRequestPanelModel::new(
  request : @posoco.UiRequest,
) -> UiRequestPanelModel {
  match request {
    @posoco.UiRequest::Input(prompt~, default~) => {
      let editor = @ui.EditorModel::new()
      match default {
        Some(text) => editor.set_text(text)
        None => ()
      }
      {
        kind: UiPanelInput,
        prompt,
        editor,
        list: @ui.SelectListModel::new([]),
      }
    }
    @posoco.UiRequest::Confirm(prompt~) => {
      {
        kind: UiPanelConfirm,
        prompt,
        editor: @ui.EditorModel::new(),
        list: @ui.SelectListModel::new(ui_request_items(["Yes", "No"])),
      }
    }
    @posoco.UiRequest::Select(prompt~, options~, default~) => {
      let list = @ui.SelectListModel::new(ui_request_items(options))
      match default {
        Some(index) => ignore(list.select(index))
        None => ()
      }
      {
        kind: UiPanelSelect,
        prompt,
        editor: @ui.EditorModel::new(),
        list,
      }
    }
  }
}

///|
pub fn UiRequestPanelModel::kind(
  self : UiRequestPanelModel,
) -> UiRequestPanelKind {
  self.kind
}

///|
pub fn UiRequestPanelModel::prompt(self : UiRequestPanelModel) -> String {
  self.prompt
}

///|
pub fn UiRequestPanelModel::input_text(
  self : UiRequestPanelModel,
) -> String {
  self.editor.text()
}

///|
pub fn UiRequestPanelModel::selected_index(
  self : UiRequestPanelModel,
) -> Int {
  self.list.selected_index()
}

///|
pub fn UiRequestPanelModel::handle_paste(
  self : UiRequestPanelModel,
  text : String,
) -> Unit {
  if self.kind == UiPanelInput {
    self.editor.insert_text(text)
  }
}

///|
fn ui_request_char(event : @ui.TerminalEvent) -> String? {
  guard event.key_code_value() is @ui.KeyChar(codepoint) else {
    return None
  }
  // Control/Alt chords are shell shortcuts, not text input. Shift is allowed:
  // Crossterm already gives us the post-layout Unicode code point.
  let non_text_modifiers =
    @ui.modifier_control() |
    @ui.modifier_alt() |
    @ui.modifier_super() |
    @ui.modifier_hyper() |
    @ui.modifier_meta()
  if (event.modifiers & non_text_modifiers) != 0U {
    return None
  }
  match codepoint.to_int().to_char() {
    Some(ch) => Some(ch.to_string())
    None => None
  }
}

///|
/// Handle one normalized key. Some(response) settles the request; None means
/// the panel remains active (whether or not the key changed local state).
pub fn UiRequestPanelModel::handle_key(
  self : UiRequestPanelModel,
  event : @ui.TerminalEvent,
) -> @posoco.UiResponse? {
  if !event.is_actionable_key() {
    return None
  }

  if event.matches_key(@ui.KeyEscape, 0U) {
    return Some(@posoco.UiResponse::Cancelled)
  }

  match self.kind {
    UiPanelInput => {
      if event.matches_key(@ui.KeyEnter, 0U) {
        return Some(@posoco.UiResponse::Text(self.editor.text()))
      }
      if event.matches_key(@ui.KeyBackspace, 0U) {
        self.editor.backspace()
        return None
      }
      if event.matches_key(@ui.KeyDelete, 0U) {
        self.editor.delete_forward()
        return None
      }
      if event.matches_key(@ui.KeyLeft, 0U) {
        self.editor.move_left()
        return None
      }
      if event.matches_key(@ui.KeyRight, 0U) {
        self.editor.move_right()
        return None
      }
      if event.matches_key(@ui.KeyUp, 0U) {
        self.editor.move_up()
        return None
      }
      if event.matches_key(@ui.KeyDown, 0U) {
        self.editor.move_down()
        return None
      }
      if event.matches_key(@ui.KeyHome, 0U) {
        self.editor.move_home()
        return None
      }
      if event.matches_key(@ui.KeyEnd, 0U) {
        self.editor.move_end()
        return None
      }
      match ui_request_char(event) {
        Some(text) => self.editor.insert_text(text)
        None => ()
      }
      None
    }
    UiPanelConfirm => {
      if event.matches_key(@ui.KeyUp, 0U) ||
        event.matches_key(@ui.KeyLeft, 0U) {
        self.list.previous()
        return None
      }
      if event.matches_key(@ui.KeyDown, 0U) ||
        event.matches_key(@ui.KeyRight, 0U) {
        self.list.next()
        return None
      }
      if event.matches_key(@ui.KeyEnter, 0U) {
        return if self.list.selected_index() == 1 {
          Some(@posoco.UiResponse::No)
        } else {
          Some(@posoco.UiResponse::Yes)
        }
      }
      None
    }
    UiPanelSelect => {
      if event.matches_key(@ui.KeyUp, 0U) ||
        event.matches_key(@ui.KeyLeft, 0U) {
        self.list.previous()
        return None
      }
      if event.matches_key(@ui.KeyDown, 0U) ||
        event.matches_key(@ui.KeyRight, 0U) {
        self.list.next()
        return None
      }
      if event.matches_key(@ui.KeyHome, 0U) {
        self.list.home()
        return None
      }
      if event.matches_key(@ui.KeyEnd, 0U) {
        self.list.end()
        return None
      }
      if event.matches_key(@ui.KeyEnter, 0U) {
        let index = self.list.selected_index()
        return if index >= 0 {
          Some(@posoco.UiResponse::Selected(index))
        } else {
          Some(@posoco.UiResponse::Cancelled)
        }
      }
      None
    }
  }
}
