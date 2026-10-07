///|
/// The desktop bridge deliberately uses only the stable MoonBit -> C direction.
/// Rust never calls a MoonBit callback. Commands are pulled; events are pushed.
extern "C" fn bridge_next_command_raw() -> Bytes = "cetas_gpui_bridge_next_command"

///|
extern "C" fn bridge_emit_raw(payload : Bytes) -> Unit = "cetas_gpui_bridge_emit"

///|
fn bridge_next_command() -> String {
  @utf8.decode_lossy(bridge_next_command_raw())
}

///|
fn bridge_emit_json(value : Json) -> Unit {
  bridge_emit_raw(@utf8.encode(value.stringify()))
}

///|
fn bridge_emit(
  event_type : String,
  session_id : String,
  turn_id : String,
  extra? : Array[(String, Json)] = [],
) -> Unit {
  let fields : Array[(String, Json)] = [
    ("type", Json::string(event_type)),
    ("session_id", Json::string(session_id)),
    ("turn_id", Json::string(turn_id)),
  ]
  for field in extra {
    fields.push(field)
  }
  bridge_emit_json(Json::object(Map::from_array(fields)))
}
