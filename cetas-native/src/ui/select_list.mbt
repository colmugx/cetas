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
pub fn SelectListModel::new(
  items : Array[SelectItem],
) -> SelectListModel {
  { items, selected: if items.is_empty() { -1 } else { 0 } }
}

///|
pub fn SelectListModel::is_empty(self : SelectListModel) -> Bool {
  self.items.is_empty()
}

///|
pub fn SelectListModel::selected_index(self : SelectListModel) -> Int {
  self.selected
}

///|
pub fn SelectListModel::selected_item(
  self : SelectListModel,
) -> SelectItem? {
  if self.selected < 0 || self.selected >= self.items.length() {
    return None
  }
  Some(self.items[self.selected])
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
pub fn select_list_validation_marker() -> Int {
  let list = SelectListModel::new([
    { value: "a", label: "A", description: "" },
    { value: "b", label: "B", description: "" },
    { value: "c", label: "C", description: "" },
  ])
  list.previous()
  if list.selected_index() != 2 {
    return 0
  }
  list.next()
  list.next()
  if list.selected_item() is Some(item) && item.value == "b" {
    1
  } else {
    0
  }
}
