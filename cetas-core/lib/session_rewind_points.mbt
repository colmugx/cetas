/// Physical-line-preserving rewind-point enumeration for persisted session JSONL.
///
/// posoco-ext-fs-session stores metadata on physical line 0 and one message slot
/// per following physical line. Blank or malformed lines are not rewind targets,
/// but they still occupy an address; callers must never reconstruct these
/// indexes from parsed Session.messages.

///|
pub(all) struct PersistedRewindPoint {
  message_index : Int
  preview : String
}

///|
priv struct PersistedUserContent {
  text : String
  has_image : Bool
}

///|
const REWIND_PREVIEW_MAX : Int = 60

///|
fn persisted_user_content(value : Json) -> PersistedUserContent {
  guard value is Json::Array(blocks) else {
    return { text: "", has_image: false, }
  }
  let parts : Array[String] = []
  let mut has_image = false
  for block in blocks {
    guard block is Json::Object(fields) else { continue }
    match fields.get("type") {
      Some(Json::String("text")) =>
        match fields.get("text") {
          Some(Json::String(text)) => parts.push(text)
          _ => ()
        }
      Some(Json::String("image")) => has_image = true
      _ => ()
    }
  }
  { text: parts[:].join("\n"), has_image, }
}

///|
fn single_line_rewind_preview(text : String) -> String {
  let builder = StringBuilder()
  let mut pending_space = false
  let mut wrote = false
  for ch in text {
    if ch.is_whitespace() {
      if wrote {
        pending_space = true
      }
    } else {
      if pending_space {
        builder.write_char(' ')
        pending_space = false
      }
      builder.write_char(ch)
      wrote = true
    }
  }
  builder.to_string()
}

///|
fn rewind_preview(text : String, has_image : Bool) -> String {
  let flat = single_line_rewind_preview(text)
  let joined = if has_image {
    if flat.is_empty() {
      "(image)"
    } else {
      flat + " (image)"
    }
  } else {
    flat
  }
  if joined.length() > REWIND_PREVIEW_MAX {
    joined[:REWIND_PREVIEW_MAX - 1].to_owned() + "…"
  } else {
    joined
  }
}

///|
/// Machine-injected user-shaped context must never appear as user rewind
/// targets. Mirrors cetas-js replay/rewind filtering.
fn synthetic_rewind_user_text(text : String) -> Bool {
  let trimmed = text.trim_start().to_owned()
  if trimmed.has_prefix("##") {
    let tail = trimmed[2:].to_owned().trim_start().to_owned()
    if tail == "Memory" {
      return true
    }
    if tail.has_prefix("Memory") && tail.length() > "Memory".length() {
      match tail.code_unit_at("Memory".length()).to_char() {
        Some(ch) if ch.is_whitespace() => return true
        _ => ()
      }
    }
  }

  if !trimmed.has_prefix("<") {
    return false
  }
  let tag = StringBuilder()
  let mut first = true
  for ch in trimmed {
    if first {
      first = false
      continue
    }
    if ch == '>' || ch.is_whitespace() {
      break
    }
    tag.write_char(ch)
  }
  let name = tag.to_string()
  name.length() > "-context".length() && name.has_suffix("-context")
}

///|
fn parse_persisted_user_line(line : String) -> PersistedUserContent? {
  let trimmed = line.trim().to_owned()
  if trimmed.is_empty() {
    return None
  }
  let parsed = @json.parse(trimmed) catch { _ => return None }
  guard parsed is Json::Object(fields) else { return None }
  guard fields.get("role") == Some(Json::string("user")) else { return None }
  let content = match fields.get("content") {
    Some(value) => persisted_user_content(value)
    None => { text: "", has_image: false, }
  }
  if synthetic_rewind_user_text(content.text) {
    None
  } else {
    Some(content)
  }
}

///|
/// Enumerate user rewind targets in transcript order.
///
/// The returned message_index is always physical line index minus the metadata
/// header. Skipped blank/malformed/synthetic lines still advance the address.
pub fn list_persisted_rewind_points(
  jsonl : String,
) -> Array[PersistedRewindPoint] {
  let points : Array[PersistedRewindPoint] = []
  let lines = jsonl.split("\n").map(line => line.to_owned()).to_array()
  for i in 1..<lines.length() {
    guard parse_persisted_user_line(lines[i]) is Some(content) else { continue }
    let preview = rewind_preview(content.text, content.has_image)
    if preview.is_empty() {
      continue
    }
    points.push({ message_index: i - 1, preview, })
  }
  points
}

///|
/// Read full text for one physical-line-addressed user message.
///
/// Image-only user rows return Some(""); invalid, synthetic, non-user, and
/// out-of-range rows return None.
pub fn read_persisted_rewind_user_message(
  jsonl : String,
  message_index : Int,
) -> String? {
  if message_index < 0 {
    return None
  }
  let lines = jsonl.split("\n").map(line => line.to_owned()).to_array()
  let physical = message_index + 1
  if physical < 0 || physical >= lines.length() {
    return None
  }
  match parse_persisted_user_line(lines[physical]) {
    Some(content) => Some(content.text)
    None => None
  }
}
