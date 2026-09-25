/// MoonBit-owned reducer for streamed tool-call argument state.
///
/// This ports the identity/adoption semantics from cetas-js
/// ToolStreamingController without coupling the UI reducer to JSON parsing or
/// renderer-specific tool state. Raw argument fragments are best-effort; the
/// authoritative started payload always replaces them.

///|
pub(all) struct PendingToolCallSnapshot {
  id : String?
  index : Int
  name : String?
  raw_args : String
}

///|
struct PendingToolCall {
  mut id : String?
  index : Int
  mut name : String?
  mut raw_args : String
}

///|
pub struct ToolStreamingModel {
  pending : Array[PendingToolCall]
}

///|
pub fn ToolStreamingModel::new() -> ToolStreamingModel {
  { pending: [] }
}

///|
pub fn ToolStreamingModel::pending_count(self : ToolStreamingModel) -> Int {
  self.pending.length()
}

///|
fn ToolStreamingModel::find_pending_index(
  self : ToolStreamingModel,
  index : Int,
  id : String?,
) -> Int? {
  match id {
    Some(wire_id) =>
      for i, entry in self.pending {
        if entry.id == Some(wire_id) {
          return Some(i)
        }
      }
    None => ()
  }

  for i, entry in self.pending {
    if entry.index == index {
      return Some(i)
    }
  }
  None
}

///|
/// Feed one lossy argument fragment. A later id-bearing fragment claims the
/// unique pending entry at the same provider index.
pub fn ToolStreamingModel::on_args_delta(
  self : ToolStreamingModel,
  index : Int,
  id : String?,
  name : String?,
  delta : String?,
) -> Unit {
  let pending_index = match self.find_pending_index(index, id) {
    Some(value) => value
    None => {
      self.pending.push({
        id,
        index,
        name,
        raw_args: "",
      })
      self.pending.length() - 1
    }
  }

  let entry = self.pending[pending_index]
  match id {
    Some(wire_id) =>
      if entry.id != Some(wire_id) {
        self.pending[pending_index].id = Some(wire_id)
      }
    None => ()
  }
  match name {
    Some(value) =>
      if self.pending[pending_index].name is None {
        self.pending[pending_index].name = Some(value)
      }
    None => ()
  }
  match delta {
    Some(value) =>
      if !value.is_empty() {
        self.pending[pending_index].raw_args += value
      }
    None => ()
  }
}

///|
/// Return the pending row adopted by a committed tool call.
///
/// Exact id wins. If fragments never carried an id, the sole pending entry is
/// adopted, matching cetas-js. The authoritative args replace the accumulated
/// raw buffer because the delta channel is intentionally lossy.
pub fn ToolStreamingModel::on_call_started(
  self : ToolStreamingModel,
  tool_call_id : String,
  tool_name : String,
  authoritative_args : String,
) -> PendingToolCallSnapshot? {
  let mut found : Int? = None

  for i, entry in self.pending {
    if entry.id == Some(tool_call_id) {
      found = Some(i)
      break
    }
  }

  if found is None && self.pending.length() == 1 {
    found = Some(0)
  }

  match found {
    None => None
    Some(index) => {
      let entry = self.pending.remove(index)
      Some({
        id: Some(tool_call_id),
        index: entry.index,
        name: Some(tool_name),
        raw_args: authoritative_args,
      })
    }
  }
}

///|
pub fn ToolStreamingModel::snapshot(
  self : ToolStreamingModel,
  index : Int,
) -> PendingToolCallSnapshot? {
  if index < 0 || index >= self.pending.length() {
    return None
  }
  let entry = self.pending[index]
  Some({
    id: entry.id,
    index: entry.index,
    name: entry.name,
    raw_args: entry.raw_args,
  })
}

///|
pub fn ToolStreamingModel::end_turn(self : ToolStreamingModel) -> Unit {
  self.pending.clear()
}

///|
pub fn tool_streaming_validation_marker() -> Int {
  let stream = ToolStreamingModel::new()

  // First fragment may be index-only.
  stream.on_args_delta(0, None, Some("write"), Some("{\"path\":"))
  stream.on_args_delta(0, Some("call-1"), None, Some("\"a\""))
  if stream.pending_count() != 1 {
    return 0
  }

  let pending = match stream.snapshot(0) {
    Some(value) => value
    None => return 0
  }
  if pending.id != Some("call-1") ||
    pending.name != Some("write") ||
    pending.raw_args != "{\"path\":\"a\"" {
    return 0
  }

  // Commitment consumes the pending entry and replaces lossy partial args.
  let adopted = match stream.on_call_started(
    "call-1",
    "write",
    "{\"path\":\"a\",\"content\":\"full\"}",
  ) {
    Some(value) => value
    None => return 0
  }
  if stream.pending_count() != 0 ||
    adopted.id != Some("call-1") ||
    adopted.name != Some("write") ||
    adopted.raw_args != "{\"path\":\"a\",\"content\":\"full\"}" {
    return 0
  }

  // Unknown id does not adopt when multiple calls are pending.
  stream.on_args_delta(0, None, Some("read"), Some("{}"))
  stream.on_args_delta(1, None, Some("grep"), Some("{}"))
  if stream.on_call_started("unknown", "shell", "{}") is Some(_) {
    return 0
  }

  stream.end_turn()
  if stream.pending_count() != 0 {
    return 0
  }

  1
}
