/// MoonBit-owned overlay stack and focus reducer.
///
/// The renderer only receives layered scene commands. Modal lifetime, veil
/// lifetime and keyboard focus are application/UI state and therefore remain
/// on the MoonBit side.

///|
pub(all) struct OverlayEntry {
  id : Int
  capturing : Bool
  hidden : Bool
  focused : Bool
}

///|
pub struct OverlayStack {
  entries : Array[OverlayEntry]
  mut next_id : Int
}

///|
pub fn OverlayStack::new() -> OverlayStack {
  { entries: [], next_id: 1 }
}

///|
pub fn OverlayStack::active_count(self : OverlayStack) -> Int {
  self.entries.length()
}

///|
/// The veil follows handle lifetime, matching cetas-js ModalVeilHost:
/// temporarily hidden overlays still retain the veil until their handles close.
pub fn OverlayStack::veil_visible(self : OverlayStack) -> Bool {
  !self.entries.is_empty()
}

///|
pub fn OverlayStack::visible_count(self : OverlayStack) -> Int {
  self.entries.count_if(entry => !entry.hidden)
}

///|
pub fn OverlayStack::focused_id(self : OverlayStack) -> Int? {
  for entry in self.entries {
    if entry.focused {
      return Some(entry.id)
    }
  }
  None
}

///|
fn OverlayStack::clear_focus(self : OverlayStack) -> Unit {
  for index, entry in self.entries {
    if entry.focused {
      self.entries[index] = {
        id: entry.id,
        capturing: entry.capturing,
        hidden: entry.hidden,
        focused: false,
      }
    }
  }
}

///|
fn OverlayStack::restore_top_focus(self : OverlayStack) -> Unit {
  self.clear_focus()
  let mut index = self.entries.length() - 1
  while index >= 0 {
    let entry = self.entries[index]
    if entry.capturing && !entry.hidden {
      self.entries[index] = {
        id: entry.id,
        capturing: entry.capturing,
        hidden: entry.hidden,
        focused: true,
      }
      return
    }
    index -= 1
  }
}

///|
/// Open one overlay and return its stable handle id.
///
/// Capturing overlays take keyboard focus. Non-capturing overlays (for example
/// a visual veil) participate in layering without stealing focus.
pub fn OverlayStack::open(
  self : OverlayStack,
  capturing~ : Bool = true,
) -> Int {
  let id = self.next_id
  self.next_id += 1

  if capturing {
    self.clear_focus()
  }
  self.entries.push({
    id,
    capturing,
    hidden: false,
    focused: capturing,
  })
  id
}

///|
pub fn OverlayStack::hide(
  self : OverlayStack,
  id : Int,
) -> Bool {
  for index, entry in self.entries {
    if entry.id == id {
      let removed = self.entries.remove(index)
      if removed.focused {
        self.restore_top_focus()
      }
      return true
    }
  }
  false
}

///|
/// Toggle visual visibility without releasing the overlay handle.
///
/// Hiding a focused capturing overlay transfers focus to the next visible
/// capturing overlay. Unhiding does not steal focus automatically.
pub fn OverlayStack::set_hidden(
  self : OverlayStack,
  id : Int,
  hidden : Bool,
) -> Bool {
  for index, entry in self.entries {
    if entry.id == id {
      if entry.hidden == hidden {
        return true
      }

      let was_focused = entry.focused
      self.entries[index] = {
        id: entry.id,
        capturing: entry.capturing,
        hidden,
        focused: if hidden { false } else { entry.focused },
      }

      if hidden && was_focused {
        self.restore_top_focus()
      }
      return true
    }
  }
  false
}

///|
pub fn OverlayStack::focus(
  self : OverlayStack,
  id : Int,
) -> Bool {
  for entry in self.entries {
    if entry.id == id {
      if entry.hidden || !entry.capturing {
        return false
      }
      self.clear_focus()
      for index, candidate in self.entries {
        if candidate.id == id {
          self.entries[index] = {
            id: candidate.id,
            capturing: candidate.capturing,
            hidden: candidate.hidden,
            focused: true,
          }
          return true
        }
      }
      return false
    }
  }
  false
}

///|
pub fn OverlayStack::is_hidden(
  self : OverlayStack,
  id : Int,
) -> Bool? {
  for entry in self.entries {
    if entry.id == id {
      return Some(entry.hidden)
    }
  }
  None
}

///|
pub fn overlay_validation_marker() -> Int {
  let stack = OverlayStack::new()
  let first = stack.open()
  if !stack.veil_visible() ||
    stack.active_count() != 1 ||
    stack.focused_id() != Some(first) {
    return 0
  }

  let passive = stack.open(capturing=false)
  if stack.focused_id() != Some(first) || stack.active_count() != 2 {
    return 0
  }

  let second = stack.open()
  if stack.focused_id() != Some(second) || stack.visible_count() != 3 {
    return 0
  }

  if !stack.set_hidden(second, true) ||
    stack.focused_id() != Some(first) ||
    stack.is_hidden(second) != Some(true) {
    return 0
  }

  if !stack.set_hidden(second, false) ||
    !stack.focus(second) ||
    stack.focused_id() != Some(second) {
    return 0
  }

  if !stack.hide(second) || stack.focused_id() != Some(first) {
    return 0
  }
  if !stack.hide(passive) || !stack.hide(first) || stack.veil_visible() {
    return 0
  }

  1
}
