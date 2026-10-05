/// Pure MoonBit select-list state shared by modal pickers.
///
/// Rendering and key decoding are separate concerns. This reducer owns only
/// deterministic selection semantics.

///|
pub(all) struct SelectItem {
  value : String
  label : String
  description : String
}

///|
pub struct SelectListModel {
  items : Array[SelectItem]
  mut selected : Int
}

///|
pub fn SelectListModel::new(items : Array[SelectItem]) -> SelectListModel {
  { items, selected: if items.is_empty() { -1 } else { 0 }, }
}

///|
pub fn SelectListModel::is_empty(self : SelectListModel) -> Bool {
  self.items.is_empty()
}

///|
pub fn SelectListModel::item_count(self : SelectListModel) -> Int {
  self.items.length()
}

///|
pub fn SelectListModel::item(
  self : SelectListModel,
  index : Int,
) -> SelectItem? {
  if index < 0 || index >= self.items.length() {
    None
  } else {
    Some(self.items[index])
  }
}

///|
pub fn SelectListModel::selected_index(self : SelectListModel) -> Int {
  self.selected
}

///|
pub fn SelectListModel::selected_item(self : SelectListModel) -> SelectItem? {
  if self.selected < 0 || self.selected >= self.items.length() {
    return None
  }
  Some(self.items[self.selected])
}

///|
pub fn SelectListModel::select(self : SelectListModel, index : Int) -> Bool {
  if index < 0 || index >= self.items.length() {
    return false
  }
  self.selected = index
  true
}

///|
pub fn SelectListModel::next(self : SelectListModel) -> Unit {
  let count = self.items.length()
  if count == 0 {
    self.selected = -1
    return
  }
  if self.selected < 0 || self.selected + 1 >= count {
    self.selected = 0
  } else {
    self.selected = self.selected + 1
  }
}

///|
pub fn SelectListModel::previous(self : SelectListModel) -> Unit {
  let count = self.items.length()
  if count == 0 {
    self.selected = -1
    return
  }
  if self.selected <= 0 {
    self.selected = count - 1
  } else {
    self.selected = self.selected - 1
  }
}

///|
pub fn SelectListModel::home(self : SelectListModel) -> Unit {
  self.selected = if self.items.is_empty() { -1 } else { 0 }
}

///|
pub fn SelectListModel::end(self : SelectListModel) -> Unit {
  self.selected = if self.items.is_empty() {
    -1
  } else {
    self.items.length() - 1
  }
}

///|
/// Lower this model through the native Ratatui List presentation primitive.
pub fn SelectListModel::append_scene(
  self : SelectListModel,
  builder : SceneBuilder,
  x : UInt,
  y : UInt,
  width : UInt,
  height : UInt,
) -> Unit {
  let rendered : Array[String] = []
  for item in self.items {
    if item.description.is_empty() {
      rendered.push(item.label)
    } else {
      rendered.push(item.label + "  " + item.description)
    }
  }
  builder.select_list(x, y, width, height, rendered, self.selected)
}

///|
///|
pub fn select_list_validation_marker() -> Int {
  let list = SelectListModel::new([
    { value: "a", label: "A", description: "", },
    { value: "b", label: "B", description: "", },
    { value: "c", label: "C", description: "", },
  ])
  if !list.select(1) || list.selected_index() != 1 || list.select(99) {
    return 0
  }
  list.previous()
  if list.selected_index() != 0 {
    return 0
  }
  list.next()
  list.next()
  guard list.selected_item() is Some(item) && item.value == "c" else {
    return 0
  }

  let builder = SceneBuilder::new()
  list.append_scene(builder, 0U, 0U, 24U, 3U)
  let scene = builder.finish()
  if scene.words.length() != 8 ||
    scene.words[0] != 5U ||
    scene.words[7] != 3U ||
    scene.text != @utf8.encode("A\nB\nC") {
    return 0
  }

  1
}
