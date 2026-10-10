///|
/// cetas-web client-to-server messages (WebSocket text frames). Server
/// events are the console protocol frames broadcast by the cetas-console
/// core's EventHub; only this decode lives on the transport side.
enum WebClientMessage {
  SessionAttach
  TurnStart(String, String?)
  TurnAbort(String?)
  UiResponse(String)
  SessionCompact
  StatusRefresh(String?)
}

///|
fn optional_session_id(fields : Map[String, Json]) -> String? {
  match fields.get("session_id") {
    Some(Json::String(value)) => Some(value)
    _ => None
  }
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
        Ok(TurnStart(prompt, optional_session_id(fields)))
      }
    }
    "turn.abort" => Ok(TurnAbort(optional_session_id(fields)))
    "session.compact" => Ok(SessionCompact)
    "status.refresh" => Ok(StatusRefresh(optional_session_id(fields)))
    "ui.response" => {
      let request_id = match fields.get("request_id") {
        Some(Json::String(value)) => value
        _ => return Err("ui.response.request_id must be a string")
      }
      Ok(UiResponse(request_id))
    }
    other => Err("unsupported message type: " + other)
  }
}
