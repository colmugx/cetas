///|
/// cetas-web realtime protocol v0.1.
///
/// Client messages are intentionally small commands. Server messages are
/// semantic events with a monotonically increasing `seq` plus stable
/// `event_id`, `session_id`, and `turn_id` attribution.
enum WebClientMessage {
  SessionAttach
  TurnStart(String)
  TurnAbort
}

///|
fn decode_web_client_message(raw : String) -> Result[WebClientMessage, String] {
  let parsed = @json.parse(raw) catch {
    _ => return Err("message is not valid JSON")
  }
  guard parsed is Json::Object(fields) else {
    return Err("message must be a JSON object")
  }
  let message_type = match fields.get("type") {
    Some(Json::String(value)) => value
    _ => return Err("message.type must be a string")
  }
  match message_type {
    "session.attach" => Ok(SessionAttach)
    "turn.start" => {
      let prompt = match fields.get("prompt") {
        Some(Json::String(value)) => value.trim().to_owned()
        _ => return Err("turn.start.prompt must be a string")
      }
      if prompt.is_empty() {
        Err("turn.start.prompt must not be empty")
      } else {
        Ok(TurnStart(prompt))
      }
    }
    "turn.abort" => Ok(TurnAbort)
    other => Err("unsupported message type: " + other)
  }
}

///|
struct WebObserver {
  mut sink : ((String) -> Unit)?
  mut connection_id : Int
  mut next_connection_id : Int
  mut seq : Int
  mut session_id : String
  mut turn_id : String
}

///|
fn WebObserver::new(session_id : String) -> WebObserver {
  {
    sink: None,
    connection_id: 0,
    next_connection_id: 1,
    seq: 0,
    session_id,
    turn_id: "",
  }
}

///|
fn WebObserver::attach(self : WebObserver, sink : (String) -> Unit) -> Int {
  let id = self.next_connection_id
  self.next_connection_id += 1
  self.connection_id = id
  self.sink = Some(sink)
  id
}

///|
fn WebObserver::detach(self : WebObserver, connection_id : Int) -> Unit {
  if self.connection_id == connection_id {
    self.sink = None
  }
}

///|
fn WebObserver::begin_turn(self : WebObserver, turn_id : String) -> Unit {
  self.turn_id = turn_id
}

///|
fn WebObserver::emit(
  self : WebObserver,
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
  match self.sink {
    Some(sink) => sink(Json::object(Map::from_array(fields)).stringify())
    None => ()
  }
}

///|
fn WebObserver::emit_snapshot(
  self : WebObserver,
  model : String,
  effort : String,
  cwd : String,
  busy : Bool,
) -> Unit {
  self.emit("session.snapshot", extra=[
    ("model", Json::string(model)),
    ("effort", Json::string(effort)),
    ("cwd", Json::string(cwd)),
    ("busy", Json::boolean(busy)),
    ("protocol", Json::string("cetas-web/0.1")),
  ])
}

///|
fn WebObserver::emit_protocol_error(
  self : WebObserver,
  message : String,
) -> Unit {
  self.emit("protocol.error", extra=[("message", Json::string(message))])
}

///|
fn WebObserver::emit_turn_accepted(self : WebObserver, prompt : String) -> Unit {
  self.emit("turn.accepted", extra=[("prompt", Json::string(prompt))])
}

///|
fn WebObserver::emit_turn_completed(self : WebObserver, text : String) -> Unit {
  self.emit("turn.completed", extra=[("text", Json::string(text))])
}

///|
fn WebObserver::emit_turn_failed(self : WebObserver, message : String) -> Unit {
  self.emit("turn.failed", extra=[("message", Json::string(message))])
}

///|
fn WebObserver::emit_abort_result(self : WebObserver, outcome : String) -> Unit {
  self.emit("turn.abort_result", extra=[("outcome", Json::string(outcome))])
}

///|
impl @posoco.Observer for WebObserver with fn on_event(
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
impl @posoco.Extension for WebObserver with fn extension_id(_self : WebObserver) -> String {
  "cetas_web_observer"
}

///|
impl @posoco.Extension for WebObserver with fn manifest(self : WebObserver) -> @posoco.ExtensionManifest {
  let manifest = @posoco.ExtensionManifest::default(id="cetas_web_observer")
  { ..manifest, observers: [self], }
}
