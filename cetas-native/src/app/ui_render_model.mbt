/// Persistent keyed UiRender mounts for the native terminal host.
///
/// Posoco owns the semantic slots. This model only keeps replacement
/// semantics and lowers structured bodies to human-readable terminal lines.
/// TTL is intentionally ignored for now; UiPort explicitly permits hosts to
/// ignore it.

///|
priv struct NativeRenderMount {
  slot : @posoco.UiSlot
  key : String
  lines : Array[String]
}

///|
struct NativeUiRenderModel {
  mounts : Array[NativeRenderMount]
}

///|
pub fn NativeUiRenderModel::new() -> NativeUiRenderModel {
  { mounts: [], }
}

///|
fn ui_body_lines(body : @posoco.UiBody) -> Array[String] {
  match body {
    @posoco.UiBody::Text(text) => {
      let lines : Array[String] = []
      for line in text.split("\n") {
        lines.push(line.to_owned())
      }
      lines
    }
    @posoco.UiBody::Lines(lines) => {
      let out : Array[String] = []
      out.append(lines)
      out
    }
    @posoco.UiBody::KeyValue(pairs) => {
      let lines : Array[String] = []
      for pair in pairs {
        lines.push(pair.0 + ": " + pair.1)
      }
      lines
    }
    @posoco.UiBody::Entries(entries) => {
      let lines : Array[String] = []
      for entry in entries {
        lines.push(entry.key + ": " + entry.value)
      }
      lines
    }
    @posoco.UiBody::Progress(value) => [
      "progress " + (value * 100.0).to_string() + "%",
    ]
    @posoco.UiBody::Markdown(text) => {
      let lines : Array[String] = []
      for line in text.split("\n") {
        lines.push(line.to_owned())
      }
      lines
    }
  }
}

///|
pub fn NativeUiRenderModel::apply(
  self : NativeUiRenderModel,
  intent : @posoco.UiRender,
) -> Unit {
  let lines = ui_body_lines(intent.body)
  let titled = match intent.title {
    Some(title) if !title.is_empty() => {
      if lines.is_empty() {
        [title]
      } else {
        let out : Array[String] = [title]
        out.append(lines)
        out
      }
    }
    _ => lines
  }
  for index, mount in self.mounts {
    if mount.slot == intent.slot && mount.key == intent.key {
      self.mounts[index] = { slot: intent.slot, key: intent.key, lines: titled, }
      return
    }
  }
  self.mounts.push({ slot: intent.slot, key: intent.key, lines: titled, })
}

///|
pub fn NativeUiRenderModel::line_count(self : NativeUiRenderModel) -> Int {
  let mut count = 0
  for mount in self.mounts {
    count += mount.lines.length()
  }
  count
}

///|
pub fn NativeUiRenderModel::line(
  self : NativeUiRenderModel,
  index : Int,
) -> String? {
  if index < 0 {
    return None
  }
  let mut at = 0
  for mount in self.mounts {
    for line in mount.lines {
      if at == index {
        let prefix = match mount.slot {
          @posoco.UiSlot::Status => "· "
          @posoco.UiSlot::Notice => "! "
          @posoco.UiSlot::Widget => "◇ "
        }
        return Some(prefix + line)
      }
      at += 1
    }
  }
  None
}

///|
test "native UiRender mounts replace by slot and key" {
  let model = NativeUiRenderModel::new()
  model.apply(
    @posoco.UiRender::{
      slot: @posoco.UiSlot::Status,
      key: "provider",
      title: None,
      body: @posoco.UiBody::Text("connecting"),
      ttl_ms: None,
    },
  )
  assert_eq(model.line_count(), 1)
  assert_eq(model.line(0), Some("· connecting"))
  model.apply(
    @posoco.UiRender::{
      slot: @posoco.UiSlot::Status,
      key: "provider",
      title: None,
      body: @posoco.UiBody::Text("ready"),
      ttl_ms: None,
    },
  )
  assert_eq(model.line_count(), 1)
  assert_eq(model.line(0), Some("· ready"))
  model.apply(
    @posoco.UiRender::{
      slot: @posoco.UiSlot::Widget,
      key: "quota",
      title: Some("Quota"),
      body: @posoco.UiBody::KeyValue([("5h", "82% left")]),
      ttl_ms: None,
    },
  )
  assert_eq(model.line_count(), 3)
  assert_eq(model.line(1), Some("◇ Quota"))
  assert_eq(model.line(2), Some("◇ 5h: 82% left"))
}
