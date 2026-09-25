/// Observer JSON wire parser for cetas-native.
///
/// The wire contract stays shared with cetas-js during migration. Unknown tags
/// are skipped for forward compatibility. Malformed known events fail parsing
/// so the shell can surface diagnostics without corrupting state.

///|
pub(all) enum NativeEvent {
  NativeTurnStarted
  NativeTurnCompleted
  NativeTurnFailed(String)
  NativeStreamText(String)
  NativeStreamReasoning(String)
  NativeMessageEnd(String, String)
  NativeToolArgsDelta(Int, String?, String?, String?)
  NativeToolCallStarted(String, String, String)
  NativeToolCallCompleted(String, String, Bool)
}

///|
priv enum EventParse {
  Parsed(NativeEvent)
  Skipped
  Invalid
}

///|
fn string_field(
  fields : Map[String, Json],
  key : String,
) -> String? {
  match fields.get(key) {
    Some(Json::String(value)) => Some(value)
    _ => None
  }
}

///|
fn optional_string_field(
  fields : Map[String, Json],
  key : String,
) -> (Bool, String?) {
  match fields.get(key) {
    None | Some(Json::Null) => (true, None)
    Some(Json::String(value)) => (true, Some(value))
    _ => (false, None)
  }
}

///|
fn bool_field(
  fields : Map[String, Json],
  key : String,
) -> Bool? {
  match fields.get(key) {
    Some(Json::True) => Some(true)
    Some(Json::False) => Some(false)
    _ => None
  }
}

///|
fn non_negative_int_field(
  fields : Map[String, Json],
  key : String,
) -> Int? {
  match fields.get(key) {
    Some(Json::Number(value, ..)) => {
      let int = value.to_int()
      if int >= 0 && int.to_double() == value {
        Some(int)
      } else {
        None
      }
    }
    _ => None
  }
}

///|
fn message_end_payload(value : Json) -> (String, String)? {
  guard value is Json::Object(fields) else {
    return None
  }
  guard string_field(fields, "role") == Some("assistant") else {
    return None
  }
  guard fields.get("content") is Some(Json::Array(content)) else {
    return None
  }

  let text_parts : Array[String] = []
  for block in content {
    guard block is Json::Object(block_fields) else {
      return None
    }
    match string_field(block_fields, "type") {
      Some("text") =>
        match string_field(block_fields, "text") {
          Some(text) => text_parts.push(text)
          None => return None
        }
      Some("image") =>
        if string_field(block_fields, "url") is None ||
          string_field(block_fields, "mime") is None {
          return None
        }
      _ => return None
    }
  }

  let reasoning = match fields.get("reasoning") {
    None | Some(Json::Null) => ""
    Some(Json::String(value)) => value
    _ => return None
  }
  Some((reasoning, text_parts[:].join("\n\n")))
}

///|
fn parse_one(value : Json) -> EventParse {
  if value is Json::Null {
    return Skipped
  }
  guard value is Json::Object(fields) else {
    return Invalid
  }
  guard string_field(fields, "type") is Some(kind) else {
    return Invalid
  }

  match kind {
    "turn_started" => Parsed(NativeTurnStarted)
    "turn_completed" => Parsed(NativeTurnCompleted)
    "turn_failed" =>
      match string_field(fields, "error_message") {
        Some(message) => Parsed(NativeTurnFailed(message))
        None => Invalid
      }
    "stream_chunk" => {
      guard string_field(fields, "raw") is Some(raw) else {
        return Invalid
      }
      match string_field(fields, "kind") {
        Some("text") => Parsed(NativeStreamText(raw))
        Some("reasoning") => Parsed(NativeStreamReasoning(raw))
        _ => Invalid
      }
    }
    "message_end" =>
      match fields.get("message") {
        Some(message) =>
          match message_end_payload(message) {
            Some((reasoning, text)) => Parsed(NativeMessageEnd(reasoning, text))
            None => Invalid
          }
        None => Invalid
      }
    "tool_args_delta" => {
      guard non_negative_int_field(fields, "index") is Some(index) else {
        return Invalid
      }
      let (id_ok, id) = optional_string_field(fields, "id")
      let (name_ok, name) = optional_string_field(fields, "name")
      let (delta_ok, delta) = optional_string_field(fields, "delta")
      if id_ok && name_ok && delta_ok {
        Parsed(NativeToolArgsDelta(index, id, name, delta))
      } else {
        Invalid
      }
    }
    "tool_call_started" => {
      guard string_field(fields, "tool_call_id") is Some(id) else {
        return Invalid
      }
      guard string_field(fields, "tool_name") is Some(name) else {
        return Invalid
      }
      match fields.get("args") {
        Some(args) => Parsed(NativeToolCallStarted(id, name, args.stringify()))
        None => Invalid
      }
    }
    "tool_call_completed" => {
      guard string_field(fields, "tool_call_id") is Some(id) else {
        return Invalid
      }
      guard string_field(fields, "result") is Some(result) else {
        return Invalid
      }
      match bool_field(fields, "is_error") {
        Some(is_error) => Parsed(NativeToolCallCompleted(id, result, is_error))
        None => Invalid
      }
    }
    _ => Skipped
  }
}

///|
/// Parse one observer callback payload. Model response fan-out arrives as an
/// array; ordinary events arrive as one object. Some([]) means a well-formed
/// payload containing only skip/unknown events. None means malformed input.
pub fn parse_native_events(raw : String) -> Array[NativeEvent]? {
  let parsed = @json.parse(raw) catch {
    _ => return None
  }
  let values : Array[Json] = match parsed {
    Json::Array(items) => items
    single => [single]
  }

  let events : Array[NativeEvent] = []
  for value in values {
    match parse_one(value) {
      Parsed(event) => events.push(event)
      Skipped => ()
      Invalid => return None
    }
  }
  Some(events)
}

///|
pub fn NativeShell::handle_event(
  self : NativeShell,
  event : NativeEvent,
) -> Unit {
  match event {
    NativeTurnStarted => self.begin_turn()
    NativeTurnCompleted => self.end_turn()
    NativeTurnFailed(message) => self.fail_turn(message)
    NativeStreamText(token) => self.append_text(token)
    NativeStreamReasoning(token) => self.append_reasoning(token)
    NativeMessageEnd(reasoning, text) => self.message_end(reasoning, text)
    NativeToolArgsDelta(index, id, name, delta) =>
      self.tool_args_delta(index, id, name, delta)
    NativeToolCallStarted(id, name, args) =>
      self.tool_call_started(id, name, args)
    NativeToolCallCompleted(id, result, is_error) =>
      self.tool_call_completed(id, result, is_error)
  }
}

///|
/// Parse and dispatch one observer callback payload. False means malformed
/// JSON or a malformed event with a known tag.
pub fn NativeShell::handle_event_json(
  self : NativeShell,
  raw : String,
) -> Bool {
  match parse_native_events(raw) {
    None => false
    Some(events) => {
      for event in events {
        self.handle_event(event)
      }
      true
    }
  }
}

///|
pub fn event_wire_validation_marker() -> Int {
  let shell = NativeShell::new()

  if !shell.handle_event_json("{\"type\":\"turn_started\"}") ||
    !shell.handle_event_json(
      "{\"type\":\"stream_chunk\",\"kind\":\"reasoning\",\"raw\":\"r\"}",
    ) ||
    !shell.handle_event_json(
      "{\"type\":\"stream_chunk\",\"kind\":\"text\",\"raw\":\"a\"}",
    ) {
    return 0
  }

  if !shell.handle_event_json(
    "[{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"a\"}],\"reasoning\":\"r\"}},{\"type\":\"model_invoked\",\"model\":\"\"}]",
  ) {
    return 0
  }

  if !shell.handle_event_json(
    "{\"type\":\"tool_args_delta\",\"index\":0,\"name\":\"write\",\"delta\":\"part-\"}",
  ) ||
    !shell.handle_event_json(
      "{\"type\":\"tool_args_delta\",\"index\":0,\"id\":\"call-1\",\"delta\":\"rest\"}",
    ) ||
    !shell.handle_event_json(
      "{\"type\":\"tool_call_started\",\"tool_call_id\":\"call-1\",\"tool_name\":\"write\",\"args\":{\"path\":\"a\"}}",
    ) ||
    !shell.handle_event_json(
      "{\"type\":\"tool_call_completed\",\"tool_call_id\":\"call-1\",\"result\":\"ok\",\"is_error\":false}",
    ) ||
    !shell.handle_event_json("{\"type\":\"turn_completed\"}") {
    return 0
  }

  if shell.status() != ShellIdle ||
    shell.transcript().row_count() != 3 ||
    shell.transcript().row(2).text != "✓ ok" {
    return 0
  }

  if !shell.handle_event_json("{\"type\":\"future_event\"}") ||
    shell.handle_event_json(
      "{\"type\":\"stream_chunk\",\"kind\":\"bad\",\"raw\":\"x\"}",
    ) ||
    shell.handle_event_json("{broken") {
    return 0
  }

  1
}
