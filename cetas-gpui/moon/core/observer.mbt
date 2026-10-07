/// Semantic event projection for the native desktop surface.

///|
struct DesktopObserver {
  mut seq : Int
  mut session_id : String
  mut turn_id : String
}

///|
fn DesktopObserver::new(session_id : String) -> DesktopObserver {
  { seq: 0, session_id, turn_id: "", }
}

///|
fn DesktopObserver::begin_turn(self : DesktopObserver, turn_id : String) -> Unit {
  self.turn_id = turn_id
}

///|
fn DesktopObserver::emit(
  self : DesktopObserver,
  event_type : String,
  extra? : Array[(String, Json)] = [],
) -> Unit {
  self.seq += 1
  let fields : Array[(String, Json)] = [
    ("type", Json::string(event_type)),
    ("seq", Json::number(self.seq.to_double())),
    ("event_id", Json::string("e-" + self.seq.to_string())),
    ("session_id", Json::string(self.session_id)),
    ("turn_id", Json::string(self.turn_id)),
  ]
  for field in extra {
    fields.push(field)
  }
  bridge_emit_json(Json::object(Map::from_array(fields)))
}

///|
fn DesktopObserver::emit_snapshot(
  self : DesktopObserver,
  model : String,
  effort : String,
  cwd : String,
  busy : Bool,
  permission : String,
) -> Unit {
  self.emit("session.snapshot", extra=[
    ("model", Json::string(model)),
    ("effort", Json::string(effort)),
    ("cwd", Json::string(cwd)),
    ("busy", Json::boolean(busy)),
    ("permission", Json::string(permission)),
    ("protocol", Json::string("cetas-gpui/0.1")),
  ])
}

///|
impl @posoco.Observer for DesktopObserver with fn on_event(
  self,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::TurnStarted => self.emit("turn.started")
    @posoco.TurnEvent::StreamChunkReceived(chunk~) =>
      match chunk {
        @posoco.StreamChunk::TextDelta(token~) =>
          self.emit("assistant.text_delta", extra=[
            ("delta", Json::string(token)),
          ])
        @posoco.StreamChunk::ReasoningDelta(token~) =>
          self.emit("assistant.reasoning_delta", extra=[
            ("delta", Json::string(token)),
          ])
        _ => ()
      }
    @posoco.TurnEvent::ToolCallPending(call) =>
      self.emit("tool.started", extra=[
        ("tool_call_id", Json::string(call.call_id.to_string())),
        ("tool_name", Json::string(call.name.to_string())),
        ("arguments", call.arguments),
      ])
    @posoco.TurnEvent::ToolCallSucceeded(call~, content~, ..) =>
      self.emit("tool.completed", extra=[
        ("tool_call_id", Json::string(call.call_id.to_string())),
        ("tool_name", Json::string(call.name.to_string())),
        ("result", Json::string(content)),
        ("is_error", Json::boolean(false)),
      ])
    @posoco.TurnEvent::ToolCallFailed(call~, failure~) => {
      let message = match failure {
        ReportedError(content~, ..) => content
        Runtime(category~, message~) => "\{category}: \{message}"
      }
      self.emit("tool.completed", extra=[
        ("tool_call_id", Json::string(call.call_id.to_string())),
        ("tool_name", Json::string(call.name.to_string())),
        ("result", Json::string(message)),
        ("is_error", Json::boolean(true)),
      ])
    }
    @posoco.TurnEvent::ToolCallRejected(call~, reason~) =>
      self.emit("tool.completed", extra=[
        ("tool_call_id", Json::string(call.call_id.to_string())),
        ("tool_name", Json::string(call.name.to_string())),
        ("result", Json::string(reason.to_string())),
        ("is_error", Json::boolean(true)),
      ])
    @posoco.TurnEvent::ToolCallAbandoned(call~, reason~) =>
      self.emit("tool.completed", extra=[
        ("tool_call_id", Json::string(call.call_id.to_string())),
        ("tool_name", Json::string(call.name.to_string())),
        ("result", Json::string(reason)),
        ("is_error", Json::boolean(true)),
      ])
    @posoco.TurnEvent::SessionRedirect(from~, to~, ..) => {
      self.session_id = to
      self.emit("session.redirect", extra=[
        ("from", Json::string(from)),
        ("to", Json::string(to)),
      ])
    }
    _ => ()
  }
}

///|
impl @posoco.Extension for DesktopObserver with fn extension_id(
  _self : DesktopObserver,
) -> String {
  "cetas_gpui_observer"
}

///|
impl @posoco.Extension for DesktopObserver with fn manifest(
  self : DesktopObserver,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="cetas_gpui_observer", observers=[self])
}
