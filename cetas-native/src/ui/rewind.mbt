/// Pure rewind-picker presentation state.
///
/// Session IO and rewind-point enumeration stay in the application layer.
/// This model mirrors the cetas-js RewindOverlay behavior after points have
/// already been resolved: empty input closes immediately, otherwise the first
/// item is selected, arrows wrap, Enter picks, and Escape cancels.

///|
pub(all) struct RewindPoint {
  message_index : Int
  preview : String
}

///|
pub(all) enum RewindPickerAction {
  RewindUnhandled
  RewindChanged
  RewindCancelled
  RewindPicked(Int)
} derive(Eq)

///|
pub extend RewindPickerAction with Eq::{equal, not_equal}

///|
pub struct RewindPickerModel {
  mut active : Bool
  mut points : Array[RewindPoint]
  mut list : SelectListModel
}

///|
pub fn RewindPickerModel::new() -> RewindPickerModel {
  {
    active: false,
    points: [],
    list: SelectListModel::new([]),
  }
}

///|
fn clip_rewind_label(text : String) -> String {
  let max = 64
  if text.length() <= max {
    text
  } else {
    text[:max - 1].to_owned() + "…"
  }
}

///|
/// Open with application-provided rewind points.
///
/// False means the source list was empty; callers should perform their normal
/// close/focus-restore path immediately instead of mounting an empty modal.
pub fn RewindPickerModel::open(
  self : RewindPickerModel,
  points : Array[RewindPoint],
) -> Bool {
  if points.is_empty() {
    self.active = false
    self.points = []
    self.list = SelectListModel::new([])
    return false
  }

  let items : Array[SelectItem] = []
  for point in points {
    items.push({
      value: point.message_index.to_string(),
      label: clip_rewind_label(point.preview),
      description: "message #" + point.message_index.to_string(),
    })
  }

  self.points = points
  self.list = SelectListModel::new(items)
  self.active = true
  true
}

///|
pub fn RewindPickerModel::is_active(self : RewindPickerModel) -> Bool {
  self.active
}

///|
pub fn RewindPickerModel::selected_index(self : RewindPickerModel) -> Int {
  self.list.selected_index()
}

///|
pub fn RewindPickerModel::selected_point(
  self : RewindPickerModel,
) -> RewindPoint? {
  let index = self.list.selected_index()
  if index < 0 || index >= self.points.length() {
    None
  } else {
    Some(self.points[index])
  }
}

///|
pub fn RewindPickerModel::close(self : RewindPickerModel) -> Unit {
  self.active = false
}

///|
pub fn RewindPickerModel::handle_key(
  self : RewindPickerModel,
  event : TerminalEvent,
) -> RewindPickerAction {
  if !self.active || !event.is_actionable_key() {
    return RewindUnhandled
  }

  if event.matches_key(KeyUp, 0U) {
    self.list.previous()
    return RewindChanged
  }
  if event.matches_key(KeyDown, 0U) {
    self.list.next()
    return RewindChanged
  }
  if event.matches_key(KeyEscape, 0U) {
    self.active = false
    return RewindCancelled
  }
  if event.matches_key(KeyEnter, 0U) {
    guard self.selected_point() is Some(point) else {
      self.active = false
      return RewindCancelled
    }
    self.active = false
    return RewindPicked(point.message_index)
  }

  RewindUnhandled
}

///|
fn rewind_validation_key(code : UInt) -> TerminalEvent {
  TerminalEvent::{
    abi_version: 2U,
    struct_size: 56U,
    kind: 1U,
    key_code: code,
    codepoint: 0U,
    modifiers: 0U,
    key_action: 1U,
    width: 0U,
    height: 0U,
    mouse_x: 0U,
    mouse_y: 0U,
    mouse_kind: 0U,
    mouse_button: 0U,
    text_len: 0U,
  }
}

///|
pub fn rewind_validation_marker() -> Int {
  let picker = RewindPickerModel::new()
  if picker.open([]) || picker.is_active() {
    return 0
  }

  let long_preview =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-extra"
  if !picker.open([
    { message_index: 3, preview: "first" },
    { message_index: 8, preview: long_preview },
  ]) ||
    !picker.is_active() ||
    picker.selected_index() != 0 {
    return 0
  }

  let up = rewind_validation_key(9U)
  let down = rewind_validation_key(10U)
  let enter = rewind_validation_key(2U)
  let escape = rewind_validation_key(3U)

  if picker.handle_key(up) != RewindChanged ||
    picker.selected_index() != 1 ||
    picker.handle_key(down) != RewindChanged ||
    picker.selected_index() != 0 ||
    picker.handle_key(down) != RewindChanged ||
    picker.selected_index() != 1 {
    return 0
  }

  guard picker.selected_point() is Some(selected) else {
    return 0
  }
  if selected.message_index != 8 ||
    picker.handle_key(enter) != RewindPicked(8) ||
    picker.is_active() {
    return 0
  }

  if !picker.open([{ message_index: 1, preview: "again" }]) ||
    picker.handle_key(escape) != RewindCancelled ||
    picker.is_active() {
    return 0
  }

  1
}
