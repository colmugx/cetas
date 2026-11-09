///|
/// Native terminal UI projection — explicitly opt-in.
///
/// The shared console protocol is also the browser's wire contract: it
/// broadcasts only what every web consumer parses and flattens richer intents
/// down to the smallest common shape. The native terminal host consumes the
/// same `EventHub` sink but needs the whole realtime projection:
///
/// - one distinct phase per tool lifecycle node instead of four terminal
///   states collapsing onto `is_error`,
/// - streamed tool-call argument fragments,
/// - extension `Custom` facts with their source, event scope and subagent
///   attribution,
/// - the ledger-only config / operation / chunk-backpressure facts,
/// - the unflattened `UiRender` shape.
///
/// The opt-in is one boolean on `ConsoleConfig` (`native_ui`), off by
/// default, so existing consumers keep the exact frames they already parse.
/// Nothing here polls the trace ledger: every fact is pushed through the same
/// sink as before.

///|
/// Optional string as JSON: an explicit `null` keeps the key present, so a
/// host can tell "absent" from "not applicable" without guessing.
fn native_json_string_opt(value : String?) -> Json {
  match value {
    Some(text) => Json::string(text)
    None => Json::null()
  }
}

///|
fn native_json_int_opt(value : Int32?) -> Json {
  match value {
    Some(number) => Json::number(number.to_double())
    None => Json::null()
  }
}

///|
/// Read one string field out of an extension `Custom` payload. Subagent
/// emitters embed `child_session` in the payload; `parent_call` rides there
/// only when the emitter chose to embed it.
fn native_json_string_field(data : Json, key : String) -> String {
  match data {
    Json::Object(fields) =>
      match fields.get(key) {
        Some(Json::String(value)) => value
        _ => ""
      }
    _ => ""
  }
}

///|
/// Attribution of the observed event. `None` is the pre-run/scoped-out shape
/// and stays an explicit `null` rather than being invented from the console's
/// display session id.
fn native_event_scope_json(scope : @posoco.EventScope?) -> Json {
  match scope {
    Some(scope) =>
      Json::object(
        Map::from_array([
          ("session_id", Json::string(scope.session_id.to_string())),
          ("run_id", Json::string(scope.run_id.to_string())),
          ("turn_id", Json::string(scope.turn_id.to_string())),
        ]),
      )
    None => Json::null()
  }
}

///|
/// Tool-result attachments as metadata blocks. Images keep the same
/// `media_type`/`data` pair the JS bridge already ships to its renderer; text
/// blocks stay text. The kernel never interprets the data, and neither do we.
fn native_attachment_json(attachments : Array[@posoco.Content]) -> Array[Json] {
  let items : Array[Json] = []
  for attachment in attachments {
    match attachment {
      @posoco.Content::Image(media_type~, data~) =>
        items.push(
          Json::object(
            Map::from_array([
              ("type", Json::string("image")),
              ("media_type", Json::string(media_type)),
              ("data", Json::string(data)),
            ]),
          ),
        )
      @posoco.Content::Text(text) =>
        items.push(
          Json::object(
            Map::from_array([
              ("type", Json::string("text")),
              ("text", Json::string(text)),
            ]),
          ),
        )
    }
  }
  items
}

///|
fn native_ui_slot_tag(slot : @posoco.UiSlot) -> String {
  match slot {
    @posoco.UiSlot::Status => "status"
    @posoco.UiSlot::Notice => "notice"
    @posoco.UiSlot::Widget => "widget"
  }
}

///|
/// Structured body of one render intent, mirroring the JS host's
/// `ui_render.render.body` wire shape (type discriminator plus payload).
fn native_ui_body_json(body : @posoco.UiBody) -> Json {
  match body {
    @posoco.UiBody::Text(text) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("text")),
          ("text", Json::string(text)),
        ]),
      )
    @posoco.UiBody::Lines(lines) => {
      let items : Array[Json] = []
      for line in lines {
        items.push(Json::string(line))
      }
      Json::object(
        Map::from_array([
          ("type", Json::string("lines")),
          ("lines", Json::array(items)),
        ]),
      )
    }
    @posoco.UiBody::KeyValue(pairs) => {
      let items : Array[Json] = []
      for pair in pairs {
        items.push(
          Json::object(
            Map::from_array([
              ("key", Json::string(pair.0)),
              ("value", Json::string(pair.1)),
            ]),
          ),
        )
      }
      Json::object(
        Map::from_array([
          ("type", Json::string("key_value")),
          ("entries", Json::array(items)),
        ]),
      )
    }
    @posoco.UiBody::Entries(entries) => {
      let items : Array[Json] = []
      for entry in entries {
        let fields : Array[(String, Json)] = [
          ("key", Json::string(entry.key)),
          ("value", Json::string(entry.value)),
        ]
        match entry.color {
          Some(color) => fields.push(("color", Json::string(color)))
          None => ()
        }
        items.push(Json::object(Map::from_array(fields)))
      }
      Json::object(
        Map::from_array([
          ("type", Json::string("entries")),
          ("entries", Json::array(items)),
        ]),
      )
    }
    @posoco.UiBody::Progress(current) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("progress")),
          ("current", Json::number(current)),
        ]),
      )
    @posoco.UiBody::Markdown(text) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("markdown")),
          ("text", Json::string(text)),
        ]),
      )
  }
}

///|
/// Unflattened `UiRender` shape carried next to the legacy flat fields on the
/// same `ui.render` frame. `ttl_ms` is always present (`null` = persistent) so
/// the host never has to distinguish an omitted key from an absent hint.
fn native_ui_render_json(render : @posoco.UiRender) -> Json {
  Json::object(
    Map::from_array([
      ("slot", Json::string(native_ui_slot_tag(render.slot))),
      ("key", Json::string(render.key)),
      ("title", native_json_string_opt(render.title)),
      ("body", native_ui_body_json(render.body)),
      ("ttl_ms", native_json_int_opt(render.ttl_ms)),
    ]),
  )
}
