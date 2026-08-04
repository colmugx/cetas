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
pub fn JsCallbackObserver::new(callback : JsCallback) -> JsCallbackObserver {
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
///   ToolCallResult         → tool_call_completed { tool_call_id, result, is_error }
///   ToolCallDeferred       → tool_call_deferred { tool_call_id, tool_name, reason }
///   ModelResponseReceived  → message_end { message, usage } +
///                            model_invoked { model:"", usage } (so the UI can
///                            surface token counts even when the model name is
///                            unknown to posoco's core)
///   SessionRedirect        → session_redirect { from, to }
///   StreamChunkReceived    → stream_chunk { raw } (UI may accumulate deltas)
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
      let result_text = match result {
        Success(content~, ..) => content
        ToolReportedError(content~, ..) => content
        RuntimeFailure(message~, ..) => message
        NotExecuted(..) => "not executed"
      }
      Json::object(
        Map::from_array([
          ("type", Json::string("tool_call_completed")),
          ("tool_call_id", Json::string(call.call_id.to_string())),
          ("result", Json::string(result_text)),
          ("is_error", Json::boolean(is_error)),
        ]),
      )
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
        @posoco.StreamChunk::Usage(input_tokens~, output_tokens~, total_tokens~) => {
          let u : @posoco.Usage = {
            input_tokens: Some(input_tokens),
            output_tokens: Some(output_tokens),
            total_tokens: Some(total_tokens),
          }
          Json::object(
            Map::from_array([
              ("type", Json::string("model_invoked")),
              ("model", Json::string("")),
              ("usage", usage_to_json(Some(u))),
            ]),
          )
        }
        @posoco.StreamChunk::ToolCallDelta(..) =>
          // Tool-call argument deltas arrive fragmented; the UI cannot act on
          // them until the full call resolves to ToolCallPending. Return Null
          // so on_event skips emission entirely — no wire type reaches TS.
          // (An earlier "_noop" type crashed parseCetasEvent's unknown-type
          // path. Null is the observer-level skip sentinel.)
          Json::null()
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
  // Null is the skip sentinel for chunks with no UI action (ToolCallDelta /
  // Finish). Do not emit anything — the TS parser would reject an unknown
  // `_noop` type and crash the turn mid-stream.
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
  { ..m, observers: [self] }
}

///|
pub extend JsCallbackObserver with @posoco.Extension::{extension_id, manifest}

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
pub fn JsUiPort::new(
  render_callback : JsUiRenderCallback,
  request_callback : JsUiRequestCallback,
) -> JsUiPort {
  { render_callback, request_callback, next_request_id: 0 }
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
  { ..m, ui: [self] }
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
}

///|
/// Plain positional constructor — no labeled, no optional, no defaults.
pub fn CetasJsConfig::CetasJsConfig(
  cwd : String,
  max_tool_rounds : Int,
  home : String,
) -> CetasJsConfig {
  { cwd, max_tool_rounds, home }
}

///|
/// Private stateful bridge context. It is deliberately separate from the
/// universal `CetasJsConfig`: provider catalog values (which contain opaque
/// ModelPort implementations) live only for one bridge/application instance,
/// never in the host config or renderer and never in a process-global map.
pub(all) struct CetasJsRuntime {
  config : CetasJsConfig
  catalog_cache : Map[String, @llm.ProviderModelCatalog]
}

///|
pub fn CetasJsRuntime::new(config : CetasJsConfig) -> CetasJsRuntime {
  { config, catalog_cache: Map::from_array([]) }
}

///|
/// Positional constructor exported for the JavaScript bridge. The runtime
/// remains opaque to JS; only the bridge functions can inspect its cache.
pub fn CetasJsRuntime::CetasJsRuntime(config : CetasJsConfig) -> CetasJsRuntime {
  CetasJsRuntime::new(config)
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
/// Construct the long-lived cetas-js agent.
///
/// Session transcripts are persisted below `<cwd>/.cetas/sessions`. All UI
/// callbacks are mandatory; malformed callback responses fail the request.
pub fn cetas_js_create_agent(
  config : CetasJsConfig,
  observer_callback : JsCallback,
  render_callback : JsUiRenderCallback,
  request_callback : JsUiRequestCallback,
  cancel_check : JsCancelCheck,
) -> @js_async.Promise[CetasJsAgent] {
  cetas_js_runtime_create_agent(
    CetasJsRuntime::new(config),
    observer_callback,
    render_callback,
    request_callback,
    cancel_check,
  )
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
    let cred_store = credential_store(runtime.config.cwd)
    let auth_interaction = JsAuthInteraction::new(
      observer_callback, request_callback, cancel_check,
    )
    let model = build_provider_router(runtime, cred_store, auth_interaction)
    let store = @fs_session.JsonlSessionStore::new(
      runtime.config.cwd + "/.cetas/sessions",
    )
    let profile_errors : Array[String] = []
    let observer = JsCallbackObserver::new(observer_callback)
    let ui = JsUiPort::new(render_callback, request_callback)
    // Load AGENTS.md / CLAUDE.md context files from home + cwd ancestor
    // chain through the shared workspace fs boundary. Failures are swallowed
    // (empty bundle); context is best-effort.
    let context_fs = @workspace.JsWorkspaceFs::new()
    let loader = @context.ContextLoader::new(
      context_fs,
      home=runtime.config.home,
    )
    let bundle = loader.load(runtime.config.cwd) catch {
      _ => @context.ContextBundle::empty()
    }
    let context_contributor = @context.ContextPromptContributor::new(bundle~)
    // Cetas product extension: identity + system-prompt assembly + /profile.
    let cetas = @cetas_core.Cetas::Cetas(
      cwd=runtime.config.cwd,
      ui=ui as &@posoco.UiPort,
      context_contributor=Some(
        context_contributor as &@posoco.SystemPromptContributor,
      ),
      list_profiles=fn() {
        list_profile_files(
          runtime.config.cwd + "/.cetas/profiles",
          profile_errors,
        )
      },
      on_load=fn(name : String) {
        load_profile(
          runtime.config.cwd + "/.cetas/profiles",
          runtime.config.cwd + "/.cetas/settings.json",
          name,
          profile_errors,
        )
      },
      on_save=fn(name : String) {
        save_profile(
          runtime.config.cwd + "/.cetas/profiles",
          runtime.config.cwd + "/.cetas/settings.json",
          name,
          profile_errors,
        )
      },
      on_delete=fn(name : String) {
        delete_profile(
          runtime.config.cwd + "/.cetas/profiles",
          name,
          profile_errors,
        )
      },
    )
    // Plan mode: read-only investigation gated by PreToolHook, toggled via
    // /plan or shift+tab (declared on the command's shortcut), model entry
    // via enter_plan_mode, exit only via plan.approve.
    let plan_mode = @plan.PlanMode::new(config=@plan.PlanModeConfig::{
      ..@plan.PlanModeConfig::default(),
      allowed_tools: ["read", "glob", "grep"],
      allow_model_entry: true,
    })
    // Status bar: data-driven status-line segments rendered over the shared
    // JsUiPort (slot Status, key "statusbar"); the host mounts that key in
    // whichever region its layout provides. Initial model facts come from
    // the freshly built router; later mutations ride invoke_command.
    let statusbar = @statusbar.StatusBar::new(ui as &@posoco.UiPort)
    push_model_facts(model, statusbar)
    let exts : Array[&@posoco.Extension] = [
      cetas,
      model as &@posoco.Extension,
      store as &@posoco.Extension,
      observer as &@posoco.Extension,
      ui as &@posoco.Extension,
      plan_mode,
      statusbar,
    ]
    for tool in @cetas_core.build_default_features() {
      exts.push(tool)
    }
    let agent = @posoco.Agent(exts~, config={
      max_tool_rounds: runtime.config.max_tool_rounds,
      temperature: None,
      max_output_tokens: None,
      model_context_window: None,
    })
    { agent, profile_errors, router: model, statusbar }
  }
}

///|
/// Async JS export for setup discovery.  It has no Agent side effects.
pub fn cetas_js_describe_setup(
  config : CetasJsConfig,
) -> @js_async.Promise[String] {
  cetas_js_runtime_describe_setup(CetasJsRuntime::new(config))
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
    CetasJsRuntime::new(config),
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
    CetasJsRuntime::new(config),
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
pub fn cetas_js_run_turn(
  handle : CetasJsAgent,
  prompt : String,
  session_id : String,
) -> @js_async.Promise[String] {
  @js_async.Promise::from_async() <| () => {
    let started = host_now_ms()
    handle.statusbar.set_session(session_id)
    let result : Result[String, Error] = Ok(
      @cetas_core.run_prompt(handle.agent, prompt, session_id),
    ) catch {
      err => Err(err)
    }
    handle.statusbar.set_latency((host_now_ms() - started).to_int())
    match result {
      Ok(text) => text
      Err(err) => raise err
    }
  }
}

///|
/// Shut down the long-lived agent. Cleanup failures reject the returned
/// Promise and remain visible to the JS host.
pub fn cetas_js_shutdown(handle : CetasJsAgent) -> @js_async.Promise[Unit] {
  @js_async.Promise::from_async() <| () => { handle.agent.shutdown() }
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
          // Router-mutating commands keep the status bar in sync: the
          // invocation already committed the change, so mirror it as facts.
          if id == "model" || id == "effort" {
            match outcome {
              Success(..) => push_model_facts(handle.router, handle.statusbar)
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
