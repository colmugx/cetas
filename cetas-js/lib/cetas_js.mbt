///|
/// cetas_js.mbt — JS host assembly for cetas-js.
///
/// Composes the provider-owned model router, generic coding-tool features,
/// cetas-core's session store, and JsCallbackObserver into a Posoco Agent.

///|
/// JS callback type: `(eventJson: string) => void`.
/// Public because JsCallbackObserver exposes it in its constructor.
#external
pub type JsCallback

///|
/// JS callback used by provider OAuth polling to observe host cancellation.
#external
pub type JsCancelCheck

///|
extern "js" fn JsCallback::invoke(self : JsCallback, arg : String) -> Unit =
  #| (cb, arg) => cb(arg)

///|
extern "js" fn JsCancelCheck::is_cancelled(self : JsCancelCheck) -> Bool =
  #| (cb) => cb()

///|
/// Observer that forwards every TurnEvent to a registered JS callback,
/// serialised as JSON. The TS side parses and renders.
pub(all) struct JsCallbackObserver {
  callback : JsCallback
}

///|
pub fn JsCallbackObserver::JsCallbackObserver(
  callback : JsCallback,
) -> JsCallbackObserver {
  { callback, }
}

///|
/// Convert a Content block to its JSON wire form: `{type:"text",text}` or
/// `{type:"image",url,mime}`. The UI only consumes the text form today;
/// image blocks pass through for future renderers.
fn content_to_json(c : @posoco.Content) -> Json {
  match c {
    @posoco.Content::Text(t) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("text")),
          ("text", Json::string(t)),
        ]),
      )
    @posoco.Content::Image(media_type~, data~) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("image")),
          ("url", Json::string(data)),
          ("mime", Json::string(media_type)),
        ]),
      )
  }
}

///|
/// Build the BridgeMessage payload for message_* events. Push model: every
/// field the UI may want is emitted so the TS side can do a full replace on
/// each `message_update`.
fn message_to_json(msg : @posoco.Message) -> Json {
  let (content_blocks, tool_calls, reasoning_str) = match msg {
    AssistantMessage(content~, tool_calls~, reasoning~, ..) => {
      // Read the inner String directly. `Reasoning`'s custom `Show` impl
      // (domain_message.mbt:117) renders only a length summary
      // ("Reasoning(N chars)"), so `r.to_string()` would leak that Debug form
      // to the wire — Bug #2-a.
      let r = match reasoning {
        Some(r) => Some(r.content)
        None => None
      }
      (content, tool_calls, r)
    }
    UserMessage(content~) | SystemMessage(content~) => (content, [], None)
    ToolMessage(..) => ([], [], None)
  }
  let content_arr : Array[Json] = []
  for c in content_blocks {
    content_arr.push(content_to_json(c))
  }
  let fields : Array[(String, Json)] = [
    ("role", Json::string("assistant")),
    ("content", Json::array(content_arr)),
  ]
  if tool_calls.length() > 0 {
    let tc_arr : Array[Json] = []
    for tc in tool_calls {
      tc_arr.push(
        Json::object(
          Map::from_array([
            ("id", Json::string(tc.call_id.to_string())),
            ("name", Json::string(tc.name.to_string())),
            ("arguments", Json::string(tc.arguments.stringify())),
          ]),
        ),
      )
    }
    fields.push(("toolCalls", Json::array(tc_arr)))
  }
  match reasoning_str {
    Some(r) => fields.push(("reasoning", Json::string(r)))
    None => ()
  }
  Json::object(Map::from_array(fields))
}

///|
/// Usage payload — omit nullish fields so the TS side can rely on absence.
fn usage_to_json(usage : @posoco.Usage?) -> Json {
  match usage {
    None => Json::null()
    Some(u) => {
      let fields : Array[(String, Json)] = []
      match u.input_tokens {
        Some(v) => fields.push(("input_tokens", Json::number(v.to_double())))
        None => ()
      }
      match u.output_tokens {
        Some(v) => fields.push(("output_tokens", Json::number(v.to_double())))
        None => ()
      }
      match u.total_tokens {
        Some(v) => fields.push(("total_tokens", Json::number(v.to_double())))
        None => ()
      }
      match u.cached_input_tokens {
        Some(v) =>
          fields.push(("cached_input_tokens", Json::number(v.to_double())))
        None => ()
      }
      match u.uncached_input_tokens {
        Some(v) =>
          fields.push(("uncached_input_tokens", Json::number(v.to_double())))
        None => ()
      }
      Json::object(Map::from_array(fields))
    }
  }
}

///|
/// Serialise a TurnEvent to a compact JSON string for TS consumption.
///
/// Tag mapping (posoco → cetas-js wire protocol, see src/events.ts):
///   TurnStarted            → turn_started
///   TurnCompleted          → turn_completed
///   TurnFailed(msg)        → turn_failed { error_message }
///   ToolCallPending        → tool_call_started { tool_call_id, tool_name, args }
///   ToolCallResult         → tool_call_completed { tool_call_id, result, is_error,
///                            structured? } (structured only when the outcome
///                            carries one — reserved `summary` field convention)
///   ToolCallDeferred       → tool_call_deferred { tool_call_id, tool_name, reason }
///   ModelResponseReceived  → message_end { message, usage } +
///                            model_invoked { model:"", usage } (so the UI can
///                            surface token counts even when the model name is
///                            unknown to posoco's core)
///   SessionRedirect        → session_redirect { from, to }
///   StreamChunkReceived    → stream_chunk { raw } (UI may accumulate deltas)
///     ToolCallDelta         → tool_args_delta { index, id?, name?, delta? }
///                             (fragments concatenate into the arguments
///                             JSON string; they always precede
///                             tool_call_started, which carries the
///                             authoritative args)
///   StreamChunksDropped(_) → skipped (Json null sentinel — backpressure
///                             bookkeeping, nothing renderable)
///   Custom                 → custom { source, label, data }
fn turn_event_to_json(event : @posoco.TurnEvent) -> Json {
  let json : Json = match event {
    @posoco.TurnEvent::TurnStarted =>
      Json::object(Map::from_array([("type", Json::string("turn_started"))]))
    @posoco.TurnEvent::TurnCompleted =>
      Json::object(Map::from_array([("type", Json::string("turn_completed"))]))
    @posoco.TurnEvent::TurnFailed(msg) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("turn_failed")),
          ("error_message", Json::string(msg)),
          ("error_kind", Json::string("unknown")),
        ]),
      )
    @posoco.TurnEvent::ToolCallPending(call) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("tool_call_started")),
          ("tool_call_id", Json::string(call.call_id.to_string())),
          ("tool_name", Json::string(call.name.to_string())),
          ("args", call.arguments),
        ]),
      )
    @posoco.TurnEvent::ToolCallResult(call~, result~, is_error~) => {
      let (result_text, structured) = match result {
        Success(content~, structured~) => (content, structured)
        ToolReportedError(content~, structured~) => (content, structured)
        RuntimeFailure(message~, ..) => (message, None)
        NotExecuted(..) => ("not executed", None)
      }
      let fields : Array[(String, Json)] = [
        ("type", Json::string("tool_call_completed")),
        ("tool_call_id", Json::string(call.call_id.to_string())),
        ("result", Json::string(result_text)),
        ("is_error", Json::boolean(is_error)),
      ]
      match structured {
        Some(s) => fields.push(("structured", s))
        None => ()
      }
      Json::object(Map::from_array(fields))
    }
    // ModelResponseReceived is the closest posoco gives us to a "message_end"
    // event: it fires once per non-streaming assistant message with the full
    // Message struct. We emit both `message_end` (for transcript append) and
    // a synthetic `model_invoked` (for token/usage rendering) so the UI has
    // both shapes without a second bridge.
    @posoco.TurnEvent::ModelResponseReceived(message~, usage~) => {
      let msg_json = message_to_json(message)
      let model_invoked = Json::object(
        Map::from_array([
          ("type", Json::string("model_invoked")),
          ("model", Json::string("")),
          ("usage", usage_to_json(usage)),
        ]),
      )
      // Two events from one source: return an array and let the TS callback
      // iterate. The Observer::on_event contract is synchronous string push;
      // the JS callback handles either an object or an array payload.
      Json::array([
        Json::object(
          Map::from_array([
            ("type", Json::string("message_end")),
            ("message", msg_json),
          ]),
        ),
        model_invoked,
      ])
    }
    @posoco.TurnEvent::ToolCallDeferred(call~, reason~) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("tool_call_deferred")),
          ("tool_call_id", Json::string(call.call_id.to_string())),
          ("tool_name", Json::string(call.name.to_string())),
          ("reason", Json::string(reason)),
        ]),
      )
    @posoco.TurnEvent::SessionRedirect(from~, to~, ..) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("session_redirect")),
          ("from", Json::string(from)),
          ("to", Json::string(to)),
        ]),
      )
    @posoco.TurnEvent::StreamChunkReceived(chunk~) =>
      // The UI accumulates text/reasoning deltas into a draft message. We
      // pass the raw chunk fields through rather than re-stringifying a
      // nested object so the TS side can read them directly.
      match chunk {
        @posoco.StreamChunk::TextDelta(token~) =>
          Json::object(
            Map::from_array([
              ("type", Json::string("stream_chunk")),
              ("raw", Json::string(token)),
              ("kind", Json::string("text")),
            ]),
          )
        @posoco.StreamChunk::ReasoningDelta(token~) =>
          Json::object(
            Map::from_array([
              ("type", Json::string("stream_chunk")),
              ("raw", Json::string(token)),
              ("kind", Json::string("reasoning")),
            ]),
          )
        @posoco.StreamChunk::Usage(
          input_tokens~,
          output_tokens~,
          total_tokens~,
          cached_input_tokens~,
          uncached_input_tokens~
        ) => {
          let u : @posoco.Usage = {
            input_tokens: Some(input_tokens),
            output_tokens: Some(output_tokens),
            total_tokens: Some(total_tokens),
            cached_input_tokens,
            uncached_input_tokens,
          }
          Json::object(
            Map::from_array([
              ("type", Json::string("model_invoked")),
              ("model", Json::string("")),
              ("usage", usage_to_json(Some(u))),
            ]),
          )
        }
        @posoco.StreamChunk::ToolCallDelta(index~, id~, name~, arguments_delta~) => {
          // Streamed tool-call argument fragment. Fragments concatenate into
          // the full arguments JSON string; id/name ride the first fragment
          // per OpenAI convention but are carried whenever Some.
          let fields : Array[(String, Json)] = [
            ("type", Json::string("tool_args_delta")),
            ("index", Json::number(index.to_double())),
          ]
          match id {
            Some(v) => fields.push(("id", Json::string(v)))
            None => ()
          }
          match name {
            Some(v) => fields.push(("name", Json::string(v)))
            None => ()
          }
          match arguments_delta {
            Some(d) => fields.push(("delta", Json::string(d)))
            None => ()
          }
          Json::object(Map::from_array(fields))
        }
        @posoco.StreamChunk::Finish(reason~) => {
          let _ = reason
          // Finish reason is already reflected in ModelResponseReceived /
          // the subsequent turn event. No standalone UI action needed.
          Json::null()
        }
      }
    @posoco.TurnEvent::Custom(source~, label~, data~) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("custom")),
          ("source", Json::string(source)),
          ("label", Json::string(label)),
          ("data", data),
        ]),
      )
    @posoco.TurnEvent::ConfigChanged(field~, old_value~, new_value~) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("config_changed")),
          ("field", Json::string(field)),
          ("old", Json::string(old_value)),
          ("new", Json::string(new_value)),
        ]),
      )
    @posoco.TurnEvent::ConfigWarning(field~, value~, reason~) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("config_warning")),
          ("field", Json::string(field)),
          ("value", Json::string(value)),
          ("reason", Json::string(reason)),
        ]),
      )
    @posoco.TurnEvent::StreamChunksDropped(_) =>
      // Backpressure bookkeeping (oldest chunk drops). Nothing renderable;
      // an empty Json object would fail parseCetasEvent's type check, so
      // return the Null skip sentinel.
      Json::null()
  }
  json
}

///|
/// Dispatch one TurnEvent to the JS callback. When `turn_event_to_json`
/// returns an array (ModelResponseReceived fans out into message_end +
/// model_invoked), invoke the callback once per element so the TS event
/// router sees a single event per call.
pub impl @posoco.Observer for JsCallbackObserver with fn on_event(
  self,
  event : @posoco.TurnEvent,
) -> Unit {
  // Invoke is `extern "js"` and statically cannot raise; if the JS callback
  // itself throws, MoonBit's js backend surfaces it as an uncaught exception
  // (intentional — observers should not throw, and silencing would hide bugs).
  let parsed = turn_event_to_json(event)
  // Null is the skip sentinel for events with no UI action (Finish chunk /
  // StreamChunksDropped). Do not emit anything — the TS parser would reject
  // an unknown type and crash the turn mid-stream.
  match parsed {
    Json::Null => ()
    Json::Array(items) =>
      for item in items {
        self.callback.invoke(item.stringify())
      }
    single => self.callback.invoke(single.stringify())
  }
}

///|
/// Expose JsCallbackObserver as an Extension so it slots directly into
/// `Agent(exts=[...])` alongside the other cetas parts.
pub impl @posoco.Extension for JsCallbackObserver with fn extension_id(
  _self : JsCallbackObserver,
) -> String {
  "cetas_js_observer"
}

///|
pub impl @posoco.Extension for JsCallbackObserver with fn manifest(
  self : JsCallbackObserver,
) -> @posoco.ExtensionManifest {
  let m = @posoco.ExtensionManifest::empty(id="cetas_js_observer")
  { ..m, observers: [self], }
}

///|
pub extend JsCallbackObserver with @posoco.Extension::{extension_id, manifest}

///|
/// AuthInteraction adapter for MCP server login: device codes, login URLs,
/// and progress surface as observer Custom events (source "cetas-js.mcp") so
/// the TS host renders them through the normal event channel. v1 has no
/// mid-flow cancel.
struct JsMcpAuthInteraction {
  observer : JsCallbackObserver
}

///|
fn JsMcpAuthInteraction::JsMcpAuthInteraction(
  observer : JsCallbackObserver,
) -> JsMcpAuthInteraction {
  { observer, }
}

///|
pub impl @oauth.AuthInteraction for JsMcpAuthInteraction with fn notify(
  self : JsMcpAuthInteraction,
  message : @oauth.AuthMessage,
) -> Unit {
  let event : @posoco.TurnEvent = match message {
    @oauth.AuthMessage::DeviceCode(uri, code) =>
      Custom(
        source="cetas-js.mcp",
        label="mcp_login_code",
        data=Json::object(
          Map::from_array([
            ("verification_uri", Json::string(uri)),
            ("user_code", Json::string(code)),
            ("hint", Json::string("open the URL and enter the code")),
          ]),
        ),
      )
    @oauth.AuthMessage::AuthUrl(url) =>
      Custom(
        source="cetas-js.mcp",
        label="mcp_login_url",
        data=Json::object(Map::from_array([("url", Json::string(url))])),
      )
    @oauth.AuthMessage::Progress(msg) =>
      Custom(
        source="cetas-js.mcp",
        label="mcp_login_progress",
        data=Json::object(Map::from_array([("message", Json::string(msg))])),
      )
  }
  self.observer.on_event(event)
}

///|
pub impl @oauth.AuthInteraction for JsMcpAuthInteraction with fn is_cancelled(
  _self : JsMcpAuthInteraction,
) -> Bool {
  false
}

///|
pub extend JsMcpAuthInteraction with @oauth.AuthInteraction::{
  notify,
  is_cancelled,
}

///|
/// JS callback type for one-way render events: `(eventJson: string) => void`.
#external
pub type JsUiRenderCallback

///|
extern "js" fn JsUiRenderCallback::invoke(
  self : JsUiRenderCallback,
  event_json : String,
) -> Unit =
  #| (callback, eventJson) => callback(eventJson)

///|
/// JS callback type for interactive requests:
/// `(eventJson: string) => Promise<string>`.
///
/// A normal `UiPort` request resolves to the strict `ui_response` JSON shape
/// declared in `src/events.ts`; an `auth_prompt` request resolves to the
/// provider-neutral selected option id or secret text. Rejection is a host
/// failure, never an implicit cancellation.
#external
pub type JsUiRequestCallback

///|
extern "js" fn JsUiRequestCallback::invoke(
  self : JsUiRequestCallback,
  event_json : String,
) -> @js_async.Promise[String] =
  #| (callback, eventJson) => callback(eventJson)

///|
/// JS-backed UiPort. Request IDs are monotonically increasing per port and
/// are checked on the response path, so concurrent requests cannot consume
/// one another's responses.
pub(all) struct JsUiPort {
  render_callback : JsUiRenderCallback
  request_callback : JsUiRequestCallback
  mut next_request_id : Int
}

///|
/// Construct a JS UI bridge. Both callbacks are required; hosts without an
/// interactive UI must compose `NoopUiPort` instead of installing hidden
/// fallback behavior here.
pub fn JsUiPort::JsUiPort(
  render_callback : JsUiRenderCallback,
  request_callback : JsUiRequestCallback,
) -> JsUiPort {
  { render_callback, request_callback, next_request_id: 0, }
}

///|
fn ui_slot_to_json(slot : @port.UiSlot) -> Json {
  let tag = match slot {
    @port.UiSlot::Status => "status"
    @port.UiSlot::Notice => "notice"
    @port.UiSlot::Widget => "widget"
  }
  Json::string(tag)
}

///|
fn ui_body_to_json(body : @port.UiBody) -> Json {
  match body {
    @port.UiBody::Text(text) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("text")),
          ("text", Json::string(text)),
        ]),
      )
    @port.UiBody::Lines(lines) => {
      let values : Array[Json] = []
      for line in lines {
        values.push(Json::string(line))
      }
      Json::object(
        Map::from_array([
          ("type", Json::string("lines")),
          ("lines", Json::array(values)),
        ]),
      )
    }
    @port.UiBody::KeyValue(entries) => {
      let values : Array[Json] = []
      for entry in entries {
        values.push(
          Json::object(
            Map::from_array([
              ("key", Json::string(entry.0)),
              ("value", Json::string(entry.1)),
            ]),
          ),
        )
      }
      Json::object(
        Map::from_array([
          ("type", Json::string("key_value")),
          ("entries", Json::array(values)),
        ]),
      )
    }
    @port.UiBody::Progress(current) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("progress")),
          ("current", Json::number(current)),
        ]),
      )
    @port.UiBody::Markdown(text) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("markdown")),
          ("text", Json::string(text)),
        ]),
      )
  }
}

///|
fn ui_render_event_to_json(intent : @port.UiRender) -> String {
  let title_val = match intent.title {
    Some(t) => Json::string(t)
    None => Json::string("")
  }
  let render_fields : Array[(String, Json)] = [
    ("slot", ui_slot_to_json(intent.slot)),
    ("key", Json::string(intent.key)),
    ("title", title_val),
    ("body", ui_body_to_json(intent.body)),
  ]
  match intent.ttl_ms {
    Some(value) =>
      render_fields.push(("ttl_ms", Json::number(value.to_double())))
    None => ()
  }
  Json::object(
    Map::from_array([
      ("type", Json::string("ui_render")),
      ("render", Json::object(Map::from_array(render_fields))),
    ]),
  ).stringify()
}

///|
fn ui_request_to_json(req : @port.UiRequest) -> Json {
  match req {
    @port.UiRequest::Input(prompt~, default~) => {
      let fields : Array[(String, Json)] = [
        ("type", Json::string("input")),
        ("prompt", Json::string(prompt)),
      ]
      match default {
        Some(value) => fields.push(("placeholder", Json::string(value)))
        None => ()
      }
      Json::object(Map::from_array(fields))
    }
    @port.UiRequest::Confirm(prompt~) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("confirm")),
          ("prompt", Json::string(prompt)),
          ("default_yes", Json::boolean(true)),
        ]),
      )
    @port.UiRequest::Select(prompt~, options~, default~) => {
      let option_values : Array[Json] = []
      for option in options {
        option_values.push(Json::string(option))
      }
      let fields : Array[(String, Json)] = [
        ("type", Json::string("select")),
        ("title", Json::string(prompt)),
        ("options", Json::array(option_values)),
      ]
      match default {
        Some(value) =>
          fields.push(("default_index", Json::number(value.to_double())))
        None => ()
      }
      Json::object(Map::from_array(fields))
    }
  }
}

///|
fn ui_request_event_to_json(
  request_id : String,
  req : @port.UiRequest,
) -> String {
  Json::object(
    Map::from_array([
      ("type", Json::string("ui_request")),
      ("request_id", Json::string(request_id)),
      ("request", ui_request_to_json(req)),
    ]),
  ).stringify()
}

///|
fn invalid_ui_response(
  message : String,
) -> @port.UiResponse raise @error.UiError {
  raise @error.UiError::InvalidRequest(detail=message)
}

///|
fn decode_ui_response_value(
  response : Json,
  req : @port.UiRequest,
) -> @port.UiResponse raise @error.UiError {
  let fields = match response {
    Json::Object(value) => value
    _ => return invalid_ui_response("ui_response.response must be an object")
  }
  let response_type = match fields.get("type") {
    Some(Json::String(value)) => value
    _ =>
      return invalid_ui_response("ui_response.response.type must be a string")
  }
  match response_type {
    "text" =>
      match (req, fields.get("text")) {
        (@port.UiRequest::Input(_), Some(Json::String(value))) =>
          @port.UiResponse::Text(value)
        (@port.UiRequest::Input(_), _) =>
          invalid_ui_response("ui_response text requires a string text field")
        _ => invalid_ui_response("ui_response text does not match the request")
      }
    "yes" =>
      match req {
        @port.UiRequest::Confirm(_) => @port.UiResponse::Yes
        _ => invalid_ui_response("ui_response yes does not match the request")
      }
    "no" =>
      match req {
        @port.UiRequest::Confirm(_) => @port.UiResponse::No
        _ => invalid_ui_response("ui_response no does not match the request")
      }
    "selected" =>
      match (req, fields.get("index")) {
        (@port.UiRequest::Select(options~, ..), Some(Json::Number(value, ..))) =>
          if value == value.floor() &&
            value >= 0.0 &&
            value < options.length().to_double() {
            @port.UiResponse::Selected(value.to_int())
          } else {
            invalid_ui_response(
              "ui_response selected index is outside the request options",
            )
          }
        (@port.UiRequest::Select(_), _) =>
          invalid_ui_response(
            "ui_response selected requires an integer index field",
          )
        _ =>
          invalid_ui_response("ui_response selected does not match the request")
      }
    "cancelled" => @port.UiResponse::Cancelled
    _ => invalid_ui_response("ui_response.response.type is unknown")
  }
}

///|
fn raise_ui_response_error(
  error : Json,
) -> @port.UiResponse raise @error.UiError {
  let fields = match error {
    Json::Object(value) => value
    _ => return invalid_ui_response("ui_response.error must be an object")
  }
  let code = match fields.get("code") {
    Some(Json::String(value)) => value
    _ => return invalid_ui_response("ui_response.error.code must be a string")
  }
  match code {
    "cancelled" => raise @error.UiError::Cancelled
    "unsupported" =>
      raise @error.UiError::Unsupported(detail="unsupported UI response error")
    "timeout" => raise @error.UiError::IoFailure(detail="UI request timed out")
    "host_error" => {
      let message = match fields.get("message") {
        Some(Json::String(value)) => value
        _ =>
          return invalid_ui_response(
            "ui_response host_error requires a string message",
          )
      }
      raise @error.UiError::IoFailure(detail=message)
    }
    _ => invalid_ui_response("ui_response.error.code is unknown")
  }
}

///|
fn decode_ui_response_event(
  raw : String,
  expected_request_id : String,
  req : @port.UiRequest,
) -> @port.UiResponse raise @error.UiError {
  let json : Json = @json.parse(raw) catch {
    _ => return invalid_ui_response("ui_response is not valid JSON")
  }
  let fields = match json {
    Json::Object(value) => value
    _ => return invalid_ui_response("ui_response must be an object")
  }
  match fields.get("type") {
    Some(Json::String("ui_response")) => ()
    Some(Json::String(_)) =>
      return invalid_ui_response("ui_response.type must be ui_response")
    _ => return invalid_ui_response("ui_response.type must be a string")
  }
  match fields.get("request_id") {
    Some(Json::String(value)) if value == expected_request_id => ()
    Some(Json::String(_)) =>
      return invalid_ui_response("ui_response.request_id does not match")
    _ => return invalid_ui_response("ui_response.request_id must be a string")
  }
  match (fields.get("response"), fields.get("error")) {
    (Some(response), None) => decode_ui_response_value(response, req)
    (None, Some(error)) => raise_ui_response_error(error)
    (Some(_), Some(_)) =>
      invalid_ui_response(
        "ui_response must contain exactly one of response or error",
      )
    (None, None) =>
      invalid_ui_response(
        "ui_response must contain exactly one of response or error",
      )
  }
}

///|
pub impl @port.UiPort for JsUiPort with fn ui_descriptor(_self : JsUiPort) -> @port.UiDescriptor {
  @port.UiDescriptor::empty()
}

///|
pub impl @port.UiPort for JsUiPort with fn render(
  self : JsUiPort,
  intent : @port.UiRender,
) -> Unit {
  self.render_callback.invoke(ui_render_event_to_json(intent))
}

///|
pub impl @port.UiPort for JsUiPort with fn request(
  self : JsUiPort,
  req : @port.UiRequest,
) -> @port.UiResponse {
  let request_id = "ui-\{self.next_request_id}"
  self.next_request_id = self.next_request_id + 1
  let response_json = self.request_callback
    .invoke(ui_request_event_to_json(request_id, req))
    .wait() catch {
      err =>
        raise @error.UiError::IoFailure(
          detail="UI request callback rejected: \{err.to_string()}",
        )
    }
  decode_ui_response_event(response_json, request_id, req)
}

///|
/// Expose JsUiPort as an Extension so it slots directly into
/// `Agent(exts=[...])` alongside the other cetas parts.
pub impl @posoco.Extension for JsUiPort with fn extension_id(_self : JsUiPort) -> String {
  "cetas_js_ui"
}

///|
pub impl @posoco.Extension for JsUiPort with fn manifest(self : JsUiPort) -> @posoco.ExtensionManifest {
  let m = @posoco.ExtensionManifest::empty(id="cetas_js_ui")
  { ..m, ui: [self], }
}

///|
pub extend JsUiPort with @posoco.Extension::{extension_id, manifest}

///|
/// Bridge configuration. Provider settings, endpoints, model ids, and
/// credentials come from the generic settings/credential stores and are
/// interpreted by registered provider extensions; they are not host-owned
/// config.
/// `home` is the user's home directory, injected by the host (Node
/// `os.homedir()`) for AGENTS.md global lookup; this package performs no
/// home-dir resolution of its own.
/// Source: ffi.html — "#export_name is not available on functions with
/// optional arguments".
pub(all) struct CetasJsConfig {
  cwd : String
  max_tool_rounds : Int
  home : String
  permission_mode : String
  /// Root directory for session transcripts. An empty string (the bridge's
  /// "host did not choose a layout" convention) resolves to the legacy flat
  /// root `<home>/.cetas/sessions` in the constructor below.
  sessions_dir : String
  /// Host-specific /help note (TUI keys and input conventions). Empty string
  /// means no note; cetas-js owns this content because the kernel cannot know
  /// the host's keybindings.
  host_help_note : String
}

///|
/// Plain positional constructor — no labeled, no optional, no defaults.
/// `permission_mode` is `"readonly" | "workspace_write" | "interactive" |
/// "yolo"`; an unrecognized value falls back to `"workspace_write"` at policy
/// assembly. An empty `sessions_dir` falls back to `<home>/.cetas/sessions`
/// so callers that predate per-project session layout keep working. An empty
/// `host_help_note` contributes no note.
pub fn CetasJsConfig::CetasJsConfig(
  cwd : String,
  max_tool_rounds : Int,
  home : String,
  permission_mode : String,
  sessions_dir : String,
  host_help_note : String,
) -> CetasJsConfig {
  let resolved_sessions_dir = if sessions_dir == "" {
    home + "/.cetas/sessions"
  } else {
    sessions_dir
  }
  {
    cwd,
    max_tool_rounds,
    home,
    permission_mode,
    sessions_dir: resolved_sessions_dir,
    host_help_note,
  }
}

///|
/// Private stateful bridge context. It is deliberately separate from the
/// universal `CetasJsConfig`: provider catalog values (which contain opaque
/// ModelPort implementations) live only for one bridge/application instance,
/// never in the host config or renderer and never in a process-global map.
pub(all) struct CetasJsRuntime {
  config : CetasJsConfig
  catalog_cache : Map[String, @llm.ProviderModelCatalog]
  /// Providers whose last catalog build raised. Surfaced as setup warnings
  /// instead of aborting composition: one misconfigured provider must not
  /// take down the whole host.
  mut catalog_issues : Array[@cetas_core.CatalogBuildIssue]
  /// Goal condition for the next composed agent, set via `cetas_js_set_goal`
  /// before `cetas_js_runtime_create_agent`. The runner must join the Agent's
  /// extensions at composition time, so the condition cannot ride a later
  /// turn call. Empty clears it.
  mut goal_condition : String?
}

///|
/// Positional constructor exported for the JavaScript bridge. The runtime
/// remains opaque to JS; only the bridge functions can inspect its cache.
pub fn CetasJsRuntime::CetasJsRuntime(config : CetasJsConfig) -> CetasJsRuntime {
  {
    config,
    catalog_cache: Map::from_array([]),
    catalog_issues: [],
    goal_condition: None,
  }
}

///|
/// Long-lived cetas-js agent handle. The JS host constructs it once and reuses
/// it across turns so model adapters, UI correlation state, and the persistent
/// session store have one process lifetime.
///
/// The handle is intentionally opaque: JS consumers may only use the exported
/// bridge functions below and cannot bypass the Agent lifecycle boundary. A
/// profile load is reported to the TypeScript application, which then asks the
/// bridge to compose a fresh handle; the handle itself does not expose Agent
/// or provider internals.
///
/// The handle retains the provider router and the status bar so bridge entry
/// points can push bar facts (model/effort/session/latency) without
/// reconstructing composition state.
pub struct CetasJsAgent {
  agent : @posoco.Agent
  profile_errors : Array[String]
  router : @llm.RouterModelPort
  statusbar : @statusbar.StatusBar
  /// Plan-mode extension reference, so the bridge can stamp the session
  /// label onto plan file names when a session starts.
  plan : @plan.PlanMode
  /// Cetas home (`~/.cetas`) for persisting the active-model selection.
  home : String
  /// The live observer channel, so persistence warnings reach the TS host.
  observer : JsCallbackObserver
  /// Rate-limit guard, so due quota resumes can drain at the next
  /// host-driven turn (js has no long-lived task group for the monitor).
  ratelimit : @ratelimit.RateLimitGuard
  /// Goal runner when the runtime carried a goal condition at composition;
  /// `cetas_js_run_goal` drives it, regular turns ignore it.
  goal : @goal.GoalRunner?
  /// Tool name → owning extension id, snapshotted once at composition so the
  /// host can render `ext:tool_name` titles without per-event attribution.
  tool_catalog : Map[String, String]
  /// The MCP bridge seam: the intercepted `/mcp login` action drives OAuth
  /// on this instance (the same bridge the composed agent serves tools from).
  mcp : @mcp.MCPToolBridge
  /// Workspace fs handle for the MCP login credential store at command time.
  mcp_fs : &@workspace.WorkspaceFs
}

///|
/// The effort the status bar should display: the router's explicit selection
/// when one exists, otherwise the active slot's advertised default.
fn effective_effort(router : @llm.RouterModelPort) -> String? {
  match router.active_effort() {
    Some(effort) => Some(effort)
    None => {
      let active_id = router.active_slot_id()
      let mut found : String? = None
      for slot in router.list_slots() {
        if slot.id == active_id {
          found = slot.default_effort
        }
      }
      found
    }
  }
}

///|
/// Push the active model label and effective effort into the status bar.
/// Called at agent construction and after every successful /model or /effort
/// invocation so the bar tracks the router without polling.
fn push_model_facts(
  router : @llm.RouterModelPort,
  statusbar : @statusbar.StatusBar,
) -> Unit {
  statusbar.set_model(
    router.current_model_id(),
    effort=effective_effort(router),
  )
}

///|
/// Detect a legacy project-local `.cetas` directory left over from before
/// durable state moved to the user's HOME, and warn loudly once.
///
/// Before this fix, credentials, settings, profiles, and sessions were written
/// into `<cwd>/.cetas/` — i.e. the project working tree — where they could be
/// committed to a repository or shipped in an artifact. Those secrets are now
/// read and written under `<home>/.cetas/`. If a project-local `.cetas` still
/// exists AND the user has no home `.cetas` yet, they are very likely carrying
/// live credentials in their project and will appear unconfigured after this
/// change. Emit one `Custom` observer event describing the exposure and the
/// remediation (`mv <cwd>/.cetas ~/.cetas`).
///
/// This is warn-only: it never copies or deletes anything. Moving secrets
/// across a trust boundary silently is itself risky, and the user must confirm
/// where their credentials land. Best-effort and non-fatal — any filesystem
/// probe failure just suppresses the warning.
async fn warn_legacy_project_cetas(
  fs : &@workspace.WorkspaceFs,
  home : String,
  cwd : String,
  observer : &@posoco.Observer,
) -> Unit noraise {
  let legacy_path = cwd + "/.cetas"
  let home_path = home + "/.cetas"
  let legacy_present = fs.exists(legacy_path) catch { _ => return }
  if !legacy_present {
    return
  }
  let home_present = fs.exists(home_path) catch { _ => return }
  if home_present {
    return
  }
  let event : @posoco.TurnEvent = Custom(
    source="cetas-js.bridge",
    label="legacy_cetas_warning",
    data=Json::object(
      Map::from_array([
        (
          "message",
          Json::string(
            "Found a project-local .cetas directory at " +
            legacy_path +
            ". Durable state (credentials, settings, profiles, sessions) now lives under your HOME at " +
            home_path +
            ". The project-local copy may contain live credentials that are exposed to anyone with read access to this project (it can be committed or packaged). Move it out of the project tree, e.g.: mv " +
            legacy_path +
            " " +
            home_path,
          ),
        ),
        ("legacy_path", Json::string(legacy_path)),
        ("home_path", Json::string(home_path)),
      ]),
    ),
  )
  observer.on_event(event)
}

///|
/// Construct the long-lived cetas-js agent.
///
/// Session transcripts are persisted below `config.sessions_dir`, which
/// defaults to the flat `<home>/.cetas/sessions` root when the host passes
/// an empty value. All UI callbacks are mandatory; malformed callback
/// responses fail the request.
/// All durable state (credentials, settings, profiles, sessions) lives under
/// the user's HOME, never the project working tree.
pub fn cetas_js_create_agent(
  config : CetasJsConfig,
  observer_callback : JsCallback,
  render_callback : JsUiRenderCallback,
  request_callback : JsUiRequestCallback,
  cancel_check : JsCancelCheck,
) -> @js_async.Promise[CetasJsAgent] {
  cetas_js_runtime_create_agent(
    CetasJsRuntime(config),
    observer_callback,
    render_callback,
    request_callback,
    cancel_check,
  )
}

///|
/// Snapshot the tool name → owning extension id mapping from the fully
/// assembled extension list. A provider-set provenance wins when it is
/// non-empty and non-blank; the manifest id is the fallback. The core's
/// `build_tool_routing` already fails composition on duplicate tool names,
/// so entries cannot shadow each other.
fn build_tool_catalog(exts : Array[&@posoco.Extension]) -> Map[String, String] {
  let catalog : Map[String, String] = Map::from_array([])
  for ext in exts {
    let manifest = ext.manifest()
    for provider in manifest.tools {
      for def in provider.list_tools() {
        catalog[def.name.to_string()] = match def.provenance {
          Some(p) => if p.trim().length() > 0 { p } else { manifest.id }
          None => manifest.id
        }
      }
    }
  }
  catalog
}

///|
/// Stateful-runtime variant used by the TypeScript application. All provider
/// catalog construction for one application instance shares this runtime's
/// private repository; no host config or renderer stores provider internals.
pub fn cetas_js_runtime_create_agent(
  runtime : CetasJsRuntime,
  observer_callback : JsCallback,
  render_callback : JsUiRenderCallback,
  request_callback : JsUiRequestCallback,
  cancel_check : JsCancelCheck,
) -> @js_async.Promise[CetasJsAgent] {
  @js_async.Promise::from_async() <| () => {
    let cred_store = credential_store(runtime.config.home)
    let auth_interaction = JsAuthInteraction(
      observer_callback, request_callback, cancel_check,
    )
    let observer = JsCallbackObserver(observer_callback)
    let model = build_provider_router(
      runtime, cred_store, auth_interaction, observer,
    )
    let store = @fs_session.JsonlSessionStore(runtime.config.sessions_dir)
    let profile_errors : Array[String] = []
    let ui = JsUiPort(render_callback, request_callback)
    // Load AGENTS.md / CLAUDE.md context files from home + cwd ancestor
    // chain through the shared workspace fs boundary. Failures are swallowed
    // (empty bundle); context is best-effort.
    let context_fs = @workspace.JsWorkspaceFs()
    // Warn once if a legacy project-local `.cetas` (pre-HOME-relocation,
    // potentially holding live credentials) is still present. Best-effort and
    // non-fatal; never copies or deletes anything.
    warn_legacy_project_cetas(
      context_fs,
      runtime.config.home,
      runtime.config.cwd,
      observer,
    )
    let loader = @context.ContextLoader(context_fs, home=runtime.config.home)
    let bundle = loader.load(runtime.config.cwd) catch {
      _ => @context.ContextBundle::empty()
    }
    let context_contributor = @context.ContextPromptContributor(
      bundle~,
      ns="cetas",
    )
    // Cetas product extension: identity + system-prompt assembly + /profile.
    let cetas = @cetas_core.Cetas(
      cwd=runtime.config.cwd,
      ui=ui as &@posoco.UiPort,
      context_contributor=Some(
        context_contributor as &@posoco.SystemPromptContributor,
      ),
      list_profiles=fn() {
        list_profile_files(
          runtime.config.home + "/.cetas/profiles",
          profile_errors,
        )
      },
      on_load=fn(name : String) {
        load_profile(
          runtime.config.home + "/.cetas/profiles",
          runtime.config.home + "/.cetas/settings.json",
          name,
          profile_errors,
        )
      },
      on_save=fn(name : String) {
        save_profile(
          runtime.config.home + "/.cetas/profiles",
          runtime.config.home + "/.cetas/settings.json",
          name,
          profile_errors,
        )
      },
      on_delete=fn(name : String) {
        delete_profile(
          runtime.config.home + "/.cetas/profiles",
          name,
          profile_errors,
        )
      },
    )
    // Cross-extension event bus, constructed before any reporting or
    // subscribing extension so no report is dropped (fire-and-forget).
    // Extensions below share this one instance: statusbar subscribes to
    // "status" facts, the permission policy subscribes to tool-exemption
    // reports, plan mode publishes them.
    let event_bus = @devkit.EventBus()
    // Permission policy: gates write/shell/unknown tools through a UI confirm.
    // ReadOnly rejects every non-read tool without a prompt; the other modes
    // bridge through BlockingApprovalSource → JsUiPort::request (.wait()).
    // Subscribed to the bus BEFORE plan mode constructs so the enter/exit
    // tools are exempt from approval asks — their decision is the plan
    // approval flow (plan.approve / plan.reject), not a tool-permission
    // prompt.
    let mode = parse_permission_mode(runtime.config.permission_mode)
    let policy = match mode {
      @permission.ReadOnly =>
        @permission.PermissionPolicy(mode, bus=Some(event_bus))
      _ => {
        let source = BlockingApprovalSource(ui as &@posoco.UiPort)
        @permission.PermissionPolicy(
          mode,
          approval=Some(source as &@permission.ApprovalSource),
          bus=Some(event_bus),
        )
      }
    }
    // Plan mode: read-only investigation gated by Hook, toggled via
    // /plan or shift+tab (declared on the command's shortcut), model entry
    // via enter_plan_mode, exit only via plan.approve. Its enter/exit tools
    // are reported on the bus and skip the permission gate above.
    let plan_mode = @plan.PlanMode(
      config=@plan.PlanModeConfig::{
        ..@plan.PlanModeConfig::default()
        // ask_question rides the read class (permission classifies it read);
        // shell tools gate per invocation via the default shell_tools.
        ,
        allowed_tools: ["read", "glob", "grep", "ask_question"],
        allow_model_entry: true,
      },
      review=Some(
        PlanApprovalSource(ui as &@posoco.UiPort) as &@plan.PlanReviewSource,
      ),
      bus=Some(event_bus),
      // Plan-file persistence: planning narrative + named final plans go
      // to .cetas/plan/ through the workspace boundary.
      fs=Some(context_fs as &@workspace.WorkspaceFs),
    )
    // Status bar: data-driven status-line segments rendered over the shared
    // JsUiPort (slot Status, key "statusbar"); the host mounts that key in
    // whichever region its layout provides. Initial model facts come from
    // the freshly built router; later mutations ride invoke_command. The
    // cross-extension EventBus lets any extension publish status facts
    // (topic "status") the bar picks up; with no interested peer it stays
    // silent. Future extension constructors take the same bus instance.
    let statusbar = @statusbar.StatusBar(
      ui as &@posoco.UiPort,
      bus=Some(event_bus),
    )
    push_model_facts(model, statusbar)
    let exts : Array[&@posoco.Extension] = [
      cetas,
      model as &@posoco.Extension,
      store as &@posoco.Extension,
      observer as &@posoco.Extension,
      ui as &@posoco.Extension,
      plan_mode,
      statusbar,
      policy,
    ]
    // Rate-limit guard: records quota verdicts (ModelError::RateLimited) per
    // session through its Observer/PipelineHook views. js has no long-lived
    // task group for `spawn_monitor`, so due resumes drain at the next
    // host-driven turn instead (see `cetas_js_run_turn`) — the same
    // boundary-over-background-loop trade the js host makes for nmem.
    let ratelimit = @ratelimit.RateLimitGuard()
    exts.push(ratelimit as &@posoco.Extension)
    // Goal runner rides composition: its `goal_update_plan` tool must join
    // the routing table below, and the condition cannot change afterwards.
    // Regular turns are unaffected; the loop is driven explicitly by
    // `cetas_js_run_goal`.
    let goal : @goal.GoalRunner? = match runtime.goal_condition {
      Some(condition) if condition.trim().length() > 0 =>
        Some(@goal.goal_extension(goal_condition=condition))
      _ => None
    }
    match goal {
      Some(runner) => exts.push(runner as &@posoco.Extension)
      None => ()
    }
    // Default features (six tools + agent skills + ask_question) take the
    // host context: fs injection plus cwd/home. Skills policy (activation
    // budget) is single-sourced inside cetas-core; ask_question asks through
    // the same JsUiPort the approval source uses, so the TS host renders it
    // with the standard extension-UI overlays.
    for
      tool in @cetas_core.build_default_features(
        ctx={
          fs: context_fs,
          cwd: runtime.config.cwd,
          home: runtime.config.home,
        },
        ui=Some(ui as &@posoco.UiPort),
        host_help_note=if runtime.config.host_help_note == "" {
          None
        } else {
          Some(runtime.config.host_help_note)
        },
      ) {
      exts.push(tool)
    }
    // MCP servers from mcp.json (`<cwd>/.mcp.json` overriding
    // `<home>/.cetas/mcp.json`), self-governed by the ext-mcp bridge in Lazy
    // mode: servers connect in the first turn's on_start and the tool catalog
    // is admitted through the runtime seam. The static routing table and
    // catalog base are captured BEFORE the bridge joins exts (the catalog
    // source already appends the bridge's live tools). On js the mcp stdio
    // transport ignores the task group — child lifetime is owned by the
    // JS-side close choreography — so a composition-scoped group is safe even
    // though activation happens later, at the first turn.
    let mcp_bridge = match
      @mcp.MCPToolBridge::discover(
        cwd=runtime.config.cwd,
        home=runtime.config.home,
        mode=@mcp.LoadMode::Lazy,
      ) {
      Ok(bridge) => bridge
      Err(message) =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="cetas-js.mcp",
          detail=message,
        )
    }
    @async.with_task_group(group => mcp_bridge.attach(group))
    // Stored MCP OAuth credentials: refresh expired ones, then inject the
    // access tokens before lazy activation connects. Best-effort per server
    // (see mcp_inject_stored_tokens) — one unreadable record or a dead
    // authorization server degrades to the 401 shown by `/mcp`, never a
    // failed composition.
    mcp_inject_stored_tokens(
      mcp_bridge,
      mcp_credential_store(context_fs, runtime.config.home),
      @oauth.DefaultOAuthHttpTransport::DefaultOAuthHttpTransport(),
      (@async.now() / 1000L).to_int(),
    )
    let routing : Map[String, &@posoco.ToolProvider] = Map::from_array([])
    let base_defs : Array[@posoco.ToolDef] = []
    for ext in exts {
      for provider in ext.manifest().tools {
        for def in provider.list_tools() {
          routing[def.name.to_string()] = provider
          base_defs.push(def)
        }
      }
    }
    exts.push(mcp_bridge as &@posoco.Extension)
    let tool_catalog = build_tool_catalog(exts)
    // The JS FFI seam carries a plain Int (no optional arguments); the
    // bridge convention is `<= 0` = unbounded.
    let max_tool_rounds : Int? = if runtime.config.max_tool_rounds <= 0 {
      None
    } else {
      Some(runtime.config.max_tool_rounds)
    }
    // Lazy MCP activation changes the tool set mid-life, so the catalog is
    // owned by the runtime-seam source; MCP tool execution routes through
    // the decorator, everything else through the default port runtime.
    let base_runtime = @runtime.PortRuntime(
      model=model as &@posoco.ModelPort,
      tools=routing,
    )
    let mcp_runtime = @mcp.McpRuntime(
      bridge=mcp_bridge,
      fallback=base_runtime as &@runtime.Runtime,
    )
    let catalog_source = @mcp.McpCatalogSource(
      bridge=mcp_bridge,
      base_tools=base_defs,
    )
    let agent = @posoco.Agent::with_runtime(
      exts~,
      config=@cetas_core.default_agent_config(
        max_tool_rounds~,
        system_prompt=Some(
          @cetas_core.cetas_system_prompt(cwd=runtime.config.cwd),
        ),
      ),
      runtime=mcp_runtime as &@runtime.Runtime,
      catalog_source=catalog_source as &@runtime.CatalogSource,
    )
    // The guard re-runs turns itself, so it needs the composed agent.
    ratelimit.bind(agent)
    {
      agent,
      profile_errors,
      router: model,
      statusbar,
      plan: plan_mode,
      home: runtime.config.home,
      observer,
      ratelimit,
      goal,
      tool_catalog,
      mcp: mcp_bridge,
      mcp_fs: context_fs,
    }
  }
}

///|
/// Async JS export for setup discovery.  It has no Agent side effects.
pub fn cetas_js_describe_setup(
  config : CetasJsConfig,
) -> @js_async.Promise[String] {
  cetas_js_runtime_describe_setup(CetasJsRuntime(config))
}

///|
pub fn cetas_js_runtime_describe_setup(
  runtime : CetasJsRuntime,
) -> @js_async.Promise[String] {
  @js_async.Promise::from_async() <| () => { provider_setup_json(runtime) }
}

///|
/// Explicit provider-neutral model catalog refresh. An empty provider selector
/// refreshes all registered providers; a JSON array refreshes only those ids.
/// The process-lifetime cache is updated before setup JSON is returned, so a
/// subsequent `describe_setup` or Agent recomposition only reads cached data.
pub fn cetas_js_refresh_model_catalogs(
  config : CetasJsConfig,
  provider_ids_json : String,
) -> @js_async.Promise[String] {
  cetas_js_runtime_refresh_model_catalogs(
    CetasJsRuntime(config),
    provider_ids_json,
  )
}

///|
pub fn cetas_js_runtime_refresh_model_catalogs(
  runtime : CetasJsRuntime,
  provider_ids_json : String,
) -> @js_async.Promise[String] {
  @js_async.Promise::from_async() <| () => {
    refresh_model_catalogs(runtime, provider_ids_json)
  }
}

///|
/// Run provider-owned OAuth before composing an Agent. The app state machine
/// invokes this only from NeedsSetup; provider endpoint and credential details
/// stay inside the extension bridge.
pub fn cetas_js_login_provider(
  config : CetasJsConfig,
  provider_id : String,
  observer_callback : JsCallback,
  request_callback : JsUiRequestCallback,
  cancel_check : JsCancelCheck,
  method : String,
) -> @js_async.Promise[String] {
  cetas_js_runtime_login_provider(
    CetasJsRuntime(config),
    provider_id,
    observer_callback,
    request_callback,
    cancel_check,
    method,
  )
}

///|
pub fn cetas_js_runtime_login_provider(
  runtime : CetasJsRuntime,
  provider_id : String,
  observer_callback : JsCallback,
  request_callback : JsUiRequestCallback,
  cancel_check : JsCancelCheck,
  method : String,
) -> @js_async.Promise[String] {
  @js_async.Promise::from_async() <| () => {
    login_provider(
      runtime, provider_id, observer_callback, request_callback, cancel_check, method,
    )
  }
}

///|
/// Result of listing a host directory. Missing means the profile directory
/// does not exist (no profiles); Failed stays observable.
priv enum HostReaddirResult {
  Missing
  Entries(Array[String])
  Failed(String)
}

///|
/// Read a profile directory and return ProfileSpec entries (one per .json file).
/// A missing profile directory means there are no profiles; permission and
/// other filesystem errors are recorded and raised by command invocation.
///
/// Name and payload validation live in cetas-core (`valid_profile_name`,
/// `validated_profile_text`); this host only decodes the filesystem results.
fn list_profile_files(
  dir : String,
  errors : Array[String],
) -> Array[@cetas_core.ProfileSpec] {
  let entries = match decode_readdir_result(host_readdir_result(dir)) {
    Missing => return []
    Failed(message) => {
      errors.push("profile list failed: " + message)
      return []
    }
    Entries(value) => value
  }
  let specs : Array[@cetas_core.ProfileSpec] = []
  for entry in entries {
    if entry.has_suffix(".json") {
      let stem = entry.sub(end=entry.length() - 5).to_owned()
      if @cetas_core.valid_profile_name(stem) {
        specs.push(@cetas_core.ProfileSpec::ProfileSpec(stem))
      } else {
        errors.push("invalid profile filename: " + entry)
      }
    }
  }
  specs
}

///|
fn profile_path(dir : String, name : String, errors : Array[String]) -> String? {
  if !@cetas_core.valid_profile_name(name) {
    errors.push("invalid profile name: " + name)
    None
  } else {
    Some(dir + "/" + name + ".json")
  }
}

///|
/// Push the core validator's reason into the host error sink on failure.
fn validate_profile_or_record(
  text : String,
  name : String,
  errors : Array[String],
) -> String? {
  match @cetas_core.validated_profile_text(text, name) {
    Ok(value) => Some(value)
    Err(reason) => {
      errors.push(reason)
      None
    }
  }
}

///|
fn save_profile(
  dir : String,
  settings_path : String,
  name : String,
  errors : Array[String],
) -> Unit {
  let path = match profile_path(dir, name, errors) {
    Some(value) => value
    None => return
  }
  let settings = match
    decode_read_result(host_read_file_result(settings_path)) {
    @workspace.FileReadResult::Content(value) => value
    @workspace.FileReadResult::Missing => "{\"providers\":{}}"
    @workspace.FileReadResult::Failed(message) => {
      errors.push("profile settings read failed: " + message)
      return
    }
  }
  let text = match validate_profile_or_record(settings, name, errors) {
    Some(value) => value
    None => return
  }
  match decode_unit_result(host_mkdir_result(dir)) {
    Some(message) => {
      errors.push("profile directory create failed: " + message)
      return
    }
    None => ()
  }
  match decode_unit_result(host_write_file_result(path, text)) {
    Some(message) => errors.push("profile save failed: " + message)
    None => ()
  }
}

///|
fn load_profile(
  dir : String,
  settings_path : String,
  name : String,
  errors : Array[String],
) -> Unit {
  let path = match profile_path(dir, name, errors) {
    Some(value) => value
    None => return
  }
  let text = match decode_read_result(host_read_file_result(path)) {
    @workspace.FileReadResult::Content(value) => value
    @workspace.FileReadResult::Missing => {
      errors.push("profile load failed: no saved profile named " + name)
      return
    }
    @workspace.FileReadResult::Failed(message) => {
      errors.push("profile load failed: " + message)
      return
    }
  }
  let text = match validate_profile_or_record(text, name, errors) {
    Some(value) => value
    None => return
  }
  match decode_unit_result(host_write_file_result(settings_path, text)) {
    Some(message) => errors.push("profile settings write failed: " + message)
    None => ()
  }
}

///|
fn delete_profile(dir : String, name : String, errors : Array[String]) -> Unit {
  let path = match profile_path(dir, name, errors) {
    Some(value) => value
    None => return
  }
  match decode_unit_result(host_delete_file_result(path)) {
    Some(message) => errors.push("profile delete failed: " + message)
    None => ()
  }
}

///|
/// Decode the shared `{ok,value,missing,error}` read envelope into the
/// workspace-wide FileReadResult (the single missing/failed distinction).
fn decode_read_result(raw : String) -> @workspace.FileReadResult {
  let json = @json.parse(raw) catch {
    _ => return Failed("file read result is not valid JSON")
  }
  match json {
    Json::Object(fields) =>
      match fields.get("ok") {
        Some(Json::True) =>
          match fields.get("value") {
            Some(Json::String(value)) => Content(value)
            _ => Failed("file read result has no string value")
          }
        Some(Json::False) => {
          let message = match fields.get("error") {
            Some(Json::String(value)) => value
            _ => "unknown filesystem error"
          }
          match fields.get("missing") {
            Some(Json::True) => Missing
            _ => Failed(message)
          }
        }
        _ => Failed("file read result has no ok flag")
      }
    _ => Failed("file read result must be an object")
  }
}

///|
/// Decode the shared `{ok,entries,missing,error}` readdir envelope.
fn decode_readdir_result(raw : String) -> HostReaddirResult {
  let json = @json.parse(raw) catch {
    _ => return Failed("directory result is not valid JSON")
  }
  match json {
    Json::Object(fields) =>
      match fields.get("ok") {
        Some(Json::True) =>
          match fields.get("entries") {
            Some(Json::Array(items)) => {
              let entries : Array[String] = []
              for item in items {
                match item {
                  Json::String(value) => entries.push(value)
                  _ => return Failed("directory entry is not a string")
                }
              }
              Entries(entries)
            }
            _ => Failed("directory result has no entries")
          }
        Some(Json::False) =>
          match fields.get("missing") {
            Some(Json::True) => Missing
            _ => {
              let message = match fields.get("error") {
                Some(Json::String(value)) => value
                _ => "unknown filesystem error"
              }
              Failed(message)
            }
          }
        _ => Failed("directory result has no ok flag")
      }
    _ => Failed("directory result must be an object")
  }
}

///|
/// Decode the shared `{ok,error}` unit envelope; None means success.
fn decode_unit_result(raw : String) -> String? {
  let json = @json.parse(raw) catch {
    _ => return Some("filesystem result is not valid JSON")
  }
  match json {
    Json::Object(fields) =>
      match fields.get("ok") {
        Some(Json::True) => None
        Some(Json::False) =>
          match fields.get("error") {
            Some(Json::String(value)) => Some(value)
            _ => Some("unknown filesystem error")
          }
        _ => Some("filesystem result has no ok flag")
      }
    _ => Some("filesystem result must be an object")
  }
}

///|
extern "js" fn host_read_file_result(path : String) -> String =
  #| (path) => {
  #|   const fs = require("node:fs");
  #|   try {
  #|     return JSON.stringify({ ok: true, value: fs.readFileSync(path, "utf-8") });
  #|   } catch (error) {
  #|     return JSON.stringify({
  #|       ok: false,
  #|       missing: error?.code === "ENOENT",
  #|       error: String(error),
  #|     });
  #|   }
  #| }

///|
extern "js" fn host_readdir_result(path : String) -> String =
  #| (path) => {
  #|   const fs = require("node:fs");
  #|   try { return JSON.stringify({ ok: true, entries: fs.readdirSync(path) }); }
  #|   catch (error) {
  #|     return JSON.stringify({
  #|       ok: false,
  #|       missing: error?.code === "ENOENT",
  #|       error: String(error),
  #|     });
  #|   }
  #| }

///|
extern "js" fn host_mkdir_result(path : String) -> String =
  #| (path) => {
  #|   const fs = require("node:fs");
  #|   try { fs.mkdirSync(path, { recursive: true }); return JSON.stringify({ ok: true }); }
  #|   catch (error) { return JSON.stringify({ ok: false, error: String(error) }); }
  #| }

///|
extern "js" fn host_write_file_result(
  path : String,
  contents : String,
) -> String =
  #| (path, contents) => {
  #|   const fs = require("node:fs");
  #|   try { fs.writeFileSync(path, contents, "utf-8"); return JSON.stringify({ ok: true }); }
  #|   catch (error) { return JSON.stringify({ ok: false, error: String(error) }); }
  #| }

///|
extern "js" fn host_delete_file_result(path : String) -> String =
  #| (path) => {
  #|   const fs = require("node:fs");
  #|   try { fs.unlinkSync(path); return JSON.stringify({ ok: true }); }
  #|   catch (error) { return JSON.stringify({ ok: false, error: String(error) }); }
  #| }

///|
extern "js" fn host_now_ms() -> Double =
  #| () => Date.now()

///|
/// Run one turn on an existing agent handle.
///
/// Why this shape: `pub async fn` exported to JS compiles to a CPS state
/// machine that the JS host can't drive — calling `await cetas_js_run_turn()`
/// won't actually run the coroutine, and any internal `coroutine.suspend()`
/// (e.g. `Promise::wait`) panics with "no current coroutine". The official
/// bridge is `@js_async.Promise::from_async` (moonbitlang/async/src/js_async/
/// js_async.mbt:200, comment: "should only be used for exporting MoonBit code
/// to JavaScript"). It spawns a coroutine, drives it to completion, and
/// surfaces resolve/reject to JS.
///
/// Errors inside the async block become Promise rejections on the JS side
/// (stringified via `err.to_string()` per from_async's catch branch).
///
/// `signal` is the host's JS AbortSignal for this turn. When the host aborts
/// it, from_async cancels the turn coroutine: the deepest cancellable wait
/// (the in-flight model fetch) aborts its request, the loop classifies the
/// Cancelled error, and the Promise resolves with the partial transcript or
/// rejects with AbortError depending on where cancellation landed.

///|
/// Fire `cb` once when the JS AbortSignal aborts. Mirrors the package-private
/// `AbortSignal::on_abort` of moonbitlang/async (MoonBit closures compile to
/// JS functions on this backend).
extern "js" fn js_signal_on_abort(
  signal : @js_async.AbortSignal,
  cb : () -> Unit,
) -> Unit =
  #| (signal, cb) => signal.addEventListener("abort", cb, { once: true })

///|
/// Parse the host-supplied image attachment JSON: an array of
/// `{"media_type": "...", "data": "<base64|url>"}` objects. An empty string
/// means no attachments. Malformed entries are skipped, not fatal — the
/// `@path` text mention still reaches the model either way.
fn parse_image_attachments(images_json : String) -> Array[@posoco.Content] {
  let images : Array[@posoco.Content] = []
  if images_json.trim().length() == 0 {
    return images
  }
  let parsed = @json.parse(images_json) catch { _ => return images }
  match parsed {
    Json::Array(items) =>
      for item in items {
        match item {
          Json::Object(fields) => {
            let media_type = match fields.get("media_type") {
              Some(Json::String(value)) => value
              _ => continue
            }
            let data = match fields.get("data") {
              Some(Json::String(value)) => value
              _ => continue
            }
            images.push(@posoco.Content::Image(media_type~, data~))
          }
          _ => ()
        }
      }
    _ => ()
  }
  images
}

///|
/// Whether the active model slot advertises the `image_in` capability. The
/// TS host calls this before attaching `@path` images: a "false" answer
/// means attach nothing and warn (switch model via /model), matching the
/// Codex CLI attach-time gate.
pub fn cetas_js_active_model_supports_images(handle : CetasJsAgent) -> String {
  let active_id = handle.router.active_slot_id()
  for slot in handle.router.list_slots() {
    if slot.id == active_id {
      if slot.capabilities.contains("image_in") {
        return "true"
      }
      return "false"
    }
  }
  "false"
}

///|
pub fn cetas_js_run_turn(
  handle : CetasJsAgent,
  prompt : String,
  images_json : String,
  session_id : String,
  signal : @js_async.AbortSignal,
) -> @js_async.Promise[String] {
  let images = parse_image_attachments(images_json)
  let promise = @js_async.Promise::from_async(abort_signal=signal) <| () => {
    let started = host_now_ms()
    handle.statusbar.set_session(session_id)
    handle.plan.set_session_name(session_id)
    // Drain quota-verdict resumes that came due while no turn was running:
    // each is a full resumed turn on its own session, reported through the
    // normal observer channel. A drain failure must not sink the user's
    // turn, so it is swallowed here (the guard already retried or gave up
    // per its max_attempts policy).
    if !handle.ratelimit.pending_snapshots().is_empty() {
      handle.ratelimit.poll() catch {
        _ => ()
      }
    }
    let result : Result[String, Error] = Ok(
      @cetas_core.run_prompt(handle.agent, prompt, session_id, images~),
    ) catch {
      err => Err(err)
    }
    handle.statusbar.set_latency((host_now_ms() - started).to_int())
    match result {
      Ok(text) => text
      Err(err) => raise err
    }
  }
  // from_async's own signal listener cancels the turn coroutine but does not
  // pump the scheduler (`Coroutine::cancel` only marks it runnable), so a
  // cancelled turn would hang until unrelated async activity reschedules.
  // This second listener forces a reschedule round; spawning (and instantly
  // completing) a no-op coroutine is the public reschedule trigger. Listener
  // order matters: cancel runs first, the pump second.
  js_signal_on_abort(signal, fn() {
    ignore(@js_async.Promise::from_async() <| () => {  })
  })
  promise
}

///|
/// Shut down the long-lived agent. Cleanup failures reject the returned
/// Promise and remain visible to the JS host.
pub fn cetas_js_shutdown(handle : CetasJsAgent) -> @js_async.Promise[Unit] {
  @js_async.Promise::from_async() <| () => { handle.agent.shutdown() }
}

///|
/// Set the goal condition the NEXT composed agent runs under. Must be
/// called on the runtime before `cetas_js_runtime_create_agent`: the goal
/// runner's `goal_update_plan` tool has to join the Agent's extension list
/// at composition, and an empty/blank condition clears the goal.
pub fn cetas_js_set_goal(runtime : CetasJsRuntime, condition : String) -> Unit {
  if condition.trim().length() == 0 {
    runtime.goal_condition = None
  } else {
    runtime.goal_condition = Some(condition)
  }
}

///|
/// Drive the composed goal runner to completion on the given session:
/// repeated autonomous turns (charter, per-turn progress recitation,
/// verifier round) until the completion claim survives, the model declares
/// itself blocked, the budget is exhausted, or the run stalls. Each inner
/// turn streams through the normal observer channel, so the TS host renders
/// it like any other turn. Resolves with a JSON summary
/// (`{"ok":true,"status":...,"turns_completed":...,"total_tokens":...,
/// "plan":"...","stall_reason":...}`); `{"ok":false,"error":...}` when the
/// agent was composed without a goal condition.
pub fn cetas_js_run_goal(
  handle : CetasJsAgent,
  session_id : String,
) -> @js_async.Promise[String] {
  @js_async.Promise::from_async() <| () => {
    let runner = match handle.goal {
      Some(runner) => runner
      None =>
        return Json::object(
          Map::from_array([
            ("ok", Json::boolean(false)),
            (
              "error",
              Json::string(
                "no goal condition configured: call cetas_js_set_goal before creating the agent",
              ),
            ),
          ]),
        ).stringify()
    }
    let outcome : Result[@goal.GoalResult, Error] = Ok(
      runner.execute(handle.agent, session_id),
    ) catch {
      error => Err(error)
    }
    match outcome {
      Err(error) =>
        Json::object(
          Map::from_array([
            ("ok", Json::boolean(false)),
            ("error", Json::string(error.to_string())),
          ]),
        ).stringify()
      Ok(result) => {
        let fields : Array[(String, Json)] = [
          ("ok", Json::boolean(true)),
          ("status", Json::string(result.final_status.to_string())),
          ("turns_completed", Json::number(result.turns_completed.to_double())),
          (
            "total_tokens",
            Json::number(result.total_usage.total_tokens.to_double()),
          ),
          ("plan", Json::string(result.final_plan.progress_line())),
        ]
        match result.stall_reason {
          Some(reason) => fields.push(("stall_reason", Json::string(reason)))
          None => ()
        }
        Json::object(Map::from_array(fields)).stringify()
      }
    }
  }
}

///|
/// Request an abort of the active run (the JS host's ESC interrupt).
/// Synchronous and idempotent: the abort is enqueued into the control
/// mailbox and the loop observes it at its next safe point, so the pending
/// `cetas_js_run_turn` Promise then resolves with the partial transcript
/// instead of rejecting. The returned `EnqueueOutcome` string tells the host
/// which case fired (`Accepted`, `AbortAlreadyRequested`, `RejectedStale`).
pub fn cetas_js_abort_turn(handle : CetasJsAgent) -> String {
  handle.agent.control().abort_active(Some("user interrupt (esc)")).to_string()
}

///|
/// Queue a user message as a follow-up on the active run. The Agent drains
/// queued follow-ups one at a time at turn boundaries, driving a full new
/// turn per message; the host renders each drained turn via its normal
/// TurnStarted observer events. Returns the `EnqueueOutcome` string
/// (`Accepted(...)` / `RejectedStale(...)` / `RejectedQueueFull(depth=...)`)
/// so the host can fall back to a fresh turn when the run just ended.
pub fn cetas_js_enqueue_follow_up(
  handle : CetasJsAgent,
  prompt : String,
  images_json : String,
) -> String {
  let blocks : Array[@posoco.Content] = [@posoco.Content::Text(prompt)]
  for image in parse_image_attachments(images_json) {
    blocks.push(image)
  }
  let message : @posoco.Message = @posoco.Message::UserMessage(content=blocks)
  handle.agent.control().enqueue_follow_up(message).to_string()
}

///|
fn command_type_to_json(ctype : @port.CommandType) -> Json {
  let tag = match ctype {
    Action => "action"
    Toggle => "toggle"
    Select => "select"
    Input => "input"
    MultiStep => "multi_step"
  }
  Json::string(tag)
}

///|
fn param_type_to_json(ptype : @port.ParamType) -> Json {
  let tag = match ptype {
    Str => "str"
    Int => "int"
    Bool => "bool"
    Strs => "strs"
  }
  Json::string(tag)
}

///|
fn ui_hint_to_json(hint : @port.UiHint) -> Json {
  let tag = match hint {
    RefreshModelList => "refresh_model_list"
    RefreshSettings => "refresh_settings"
    ClosePanel => "close_panel"
    Toast => "toast"
    None => "none"
  }
  Json::string(tag)
}

///|
fn command_param_to_json(p : @port.CommandParam) -> Json {
  let fields : Array[(String, Json)] = [
    ("name", Json::string(p.name)),
    ("label", Json::string(p.label)),
    ("description", Json::string(p.description)),
    ("ptype", param_type_to_json(p.ptype)),
    ("required", Json::boolean(p.required)),
    ("positional", Json::boolean(p.positional)),
  ]
  match p.default {
    Some(v) => fields.push(("default", v))
    None => ()
  }
  match p.choices {
    Some(cs) => {
      let arr : Array[Json] = []
      for c in cs {
        arr.push(Json::string(c))
      }
      fields.push(("choices", Json::array(arr)))
    }
    None => ()
  }
  Json::object(Map::from_array(fields))
}

///|
fn command_def_to_json(def : @port.CommandDef) -> Json {
  let params_arr : Array[Json] = []
  for p in def.params {
    params_arr.push(command_param_to_json(p))
  }
  let aliases_arr : Array[Json] = []
  for a in def.aliases {
    aliases_arr.push(Json::string(a))
  }
  let fields : Array[(String, Json)] = [
    ("id", Json::string(def.id)),
    ("label", Json::string(def.label)),
    ("description", Json::string(def.description)),
    ("category", Json::string(def.category)),
    ("ctype", command_type_to_json(def.ctype)),
    ("params", Json::array(params_arr)),
    ("aliases", Json::array(aliases_arr)),
    ("visible", Json::boolean(def.visible)),
  ]
  match def.shortcut {
    Some(s) => fields.push(("shortcut", Json::string(s)))
    None => ()
  }
  match def.icon {
    Some(i) => fields.push(("icon", Json::string(i)))
    None => ()
  }
  match def.metadata {
    Some(m) => fields.push(("metadata", m))
    None => ()
  }
  Json::object(Map::from_array(fields))
}

///|
fn command_outcome_to_json(outcome : @port.CommandOutcome) -> Json {
  match outcome {
    Success(feedback~, structured~, ui_hint~) => {
      let fields : Array[(String, Json)] = [
        ("type", Json::string("success")),
        ("feedback", Json::string(feedback)),
      ]
      match structured {
        Some(s) => fields.push(("structured", s))
        None => ()
      }
      match ui_hint {
        Some(h) => fields.push(("ui_hint", ui_hint_to_json(h)))
        None => ()
      }
      Json::object(Map::from_array(fields))
    }
    Failure(reason~) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("failure")),
          ("reason", Json::string(reason)),
        ]),
      )
    NeedsInput(prompt~) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("needs_input")),
          ("prompt", Json::string(prompt)),
        ]),
      )
  }
}

///|
/// Enumerate all commands (built-in + extension) as a JSON array string.
/// Each entry is a serialized CommandDef. Synchronous: Agent::commands() does
/// no IO and returns the composed command ports.
pub fn cetas_js_list_commands(handle : CetasJsAgent) -> String {
  let ports = handle.agent.commands()
  let defs : Array[Json] = []
  for port in ports {
    for def in port.commands() {
      defs.push(command_def_to_json(def))
    }
  }
  Json::array(defs).stringify()
}

///|
/// The tool-name → extension-id catalog as a JSON object string, e.g.
/// `{"memory_search":"posoco_ext_nowledge_mem", ...}`; `"{}"` when the
/// composition contributes no tools. Synchronous: the catalog is a
/// composition-time snapshot (see `cetas_js_runtime_create_agent`), so the
/// TS host can render `ext:tool_name` titles without per-event attribution.
pub fn cetas_js_tool_catalog(handle : CetasJsAgent) -> String {
  let entries : Map[String, Json] = Map::from_array([])
  for name, ext_id in handle.tool_catalog {
    entries[name] = Json::string(ext_id)
  }
  Json::object(entries).stringify()
}

///|
/// Persist the router's current selection into `~/.cetas/settings.json` after
/// a successful `/model` or `/effort` so it survives restarts. A persistence
/// failure never overturns the already-committed in-memory switch: it surfaces
/// as one observer `Custom` warning and the command result stands.
async fn persist_active_model_selection(handle : CetasJsAgent) -> Unit noraise {
  @cetas_core.write_active_model_selection(
    @workspace.JsWorkspaceFs(),
    home=handle.home,
    @cetas_core.ActiveModelSelection::from_current(
      handle.router.active_slot_id(),
      handle.router.active_effort(),
    ),
  ) catch {
    _ =>
      handle.observer.on_event(
        Custom(
          source="cetas-js.bridge",
          label="active_model_persist_failed",
          data=Json::object(
            Map::from_array([
              (
                "message",
                Json::string(
                  "Failed to persist the active model selection to ~/.cetas/settings.json; the change is active for this session only.",
                ),
              ),
            ]),
          ),
        ),
      )
  }
}

///|
/// The `/mcp` command with `action:"login"` handled host-side: the
/// interactive OAuth chain needs the host's credential store and observer
/// wiring, which the bridge's read-only status command knows nothing about.
/// Returns None for every other shape (including other `mcp` actions) so
/// dispatch falls through to the owning port unchanged.
async fn mcp_login_command_outcome(
  handle : CetasJsAgent,
  id : String,
  args : Json,
) -> @port.CommandOutcome? noraise {
  if id != "mcp" {
    return None
  }
  let fields = match args {
    Json::Object(fields) => fields
    _ => return None
  }
  match fields.get("action") {
    Some(Json::String("login")) => ()
    _ => return None
  }
  let server = match fields.get("server") {
    Some(Json::String(server)) if server.trim().length() > 0 => server
    _ =>
      return Some(
        @port.CommandOutcome::Failure(reason="login requires a server name"),
      )
  }
  // Login is one-shot: the store, transport, and UI adapter are built here,
  // not retained on the handle.
  let outcome = mcp_login_flow(
    handle.mcp,
    server,
    mcp_credential_store(handle.mcp_fs, handle.home),
    @oauth.DefaultOAuthHttpTransport::DefaultOAuthHttpTransport(),
    JsMcpAuthInteraction(handle.observer),
    (@async.now() / 1000L).to_int(),
  )
  Some(
    match outcome {
      Ok(feedback) =>
        @port.CommandOutcome::Success(
          feedback~,
          structured=None,
          ui_hint=Some(@port.UiHint::None),
        )
      Err(reason) => @port.CommandOutcome::Failure(reason~)
    },
  )
}

///|
/// Invoke a command by id. Routes to the first CommandPort that declares it.
/// Returns a CommandOutcome as JSON. Unknown ids yield Failure (not a Promise
/// rejection) so the TS host can render uniformly. Errors raised by invoke
/// (CommandError::InvalidArgs / ExecutionFailed) become Promise rejections.
pub fn cetas_js_invoke_command(
  handle : CetasJsAgent,
  id : String,
  args_json : String,
) -> @js_async.Promise[String] {
  @js_async.Promise::from_async() <| () => {
    // Profile callbacks are synchronous CommandPort hooks. Keep their host
    // errors in the opaque handle until this invocation returns, then turn
    // them into a typed command failure so JS observes a rejected Promise
    // instead of a fabricated success outcome.
    handle.profile_errors.clear()
    let args = @json.parse(args_json) catch {
      _ =>
        raise @posoco.CommandError::InvalidArgs(
          reason="command arguments must be valid JSON",
        )
    }
    // `/mcp login <server>` never reaches the ports loop: the bridge's own
    // `mcp` command is read-only and would reject the action.
    match mcp_login_command_outcome(handle, id, args) {
      Some(outcome) => return command_outcome_to_json(outcome).stringify()
      None => ()
    }
    let ports = handle.agent.commands()
    let mut result_json = ""
    let mut found = false
    for port in ports {
      if !found {
        let owns = port.commands().iter().any(fn(def) { def.id == id })
        if owns {
          let outcome = port.invoke(id, args)
          if handle.profile_errors.length() > 0 {
            let message = handle.profile_errors[0]
            handle.profile_errors.clear()
            raise @posoco.CommandError::ExecutionFailed(message)
          }
          result_json = command_outcome_to_json(outcome).stringify()
          // Router-mutating commands keep the status bar in sync and persist
          // the new selection: the invocation already committed the change,
          // so mirror it as facts and make it outlive the process.
          if id == "model" || id == "effort" {
            match outcome {
              Success(..) => {
                push_model_facts(handle.router, handle.statusbar)
                persist_active_model_selection(handle)
              }
              _ => ()
            }
          }
          found = true
        }
      }
    }
    if !found {
      let miss = @port.CommandOutcome::Failure(
        reason="command not found: " + id,
      )
      result_json = command_outcome_to_json(miss).stringify()
    }
    result_json
  }
}
