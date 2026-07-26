///|
/// cetas_js.mbt — JS host assembly for cetas-js.
///
/// Composes BunDeepSeekModel + BunFsTools + BunBashTool + cetas-core's
/// InMemorySessionStore + JsCallbackObserver into a posoco Agent.

// ---------------------------------------------------------------------------
// JsCallbackObserver — bridges TurnEvent to TS via a registered callback.
// ---------------------------------------------------------------------------

///|
/// JS callback type: `(eventJson: string) => void`.
/// Public because JsCallbackObserver exposes it in its constructor.
#external
pub type JsCallback

///|
extern "js" fn JsCallback::invoke(self : JsCallback, arg : String) -> Unit =
  #| (cb, arg) => cb(arg)

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
    @posoco.Content::Image(url, mime) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("image")),
          ("url", Json::string(url)),
          ("mime", Json::string(mime)),
        ]),
      )
  }
}

///|
/// Build the BridgeMessage payload for message_* events. Push model: every
/// field the UI may want is emitted so the TS side can do a full replace on
/// each `message_update`.
fn message_to_json(msg : @posoco.Message) -> Json {
  let content_arr : Array[Json] = []
  for c in msg.content {
    content_arr.push(content_to_json(c))
  }
  let fields : Array[(String, Json)] = [
    ("role", Json::string("assistant")),
    ("content", Json::array(content_arr)),
  ]
  // Tool calls ride on Message in posoco's canonical shape.
  if msg.tool_calls.length() > 0 {
    let tc_arr : Array[Json] = []
    for tc in msg.tool_calls {
      tc_arr.push(
        Json::object(
          Map::from_array([
            ("id", Json::string(tc.id)),
            ("name", Json::string(tc.name)),
            // Arguments are already a Json object per ToolCall spec —
            // stringify so the TS side sees the OpenAI-style string form.
            ("arguments", Json::string(tc.arguments.stringify())),
          ]),
        ),
      )
    }
    fields.push(("toolCalls", Json::array(tc_arr)))
  }
  match msg.reasoning_content {
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
          ("tool_call_id", Json::string(call.id)),
          ("tool_name", Json::string(call.name)),
          // Arguments arrive as a Json value; pass through so the UI can
          // render tool-specific views (path, command, pattern, ...).
          ("args", call.arguments),
        ]),
      )
    @posoco.TurnEvent::ToolCallResult(call~, result~, is_error~) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("tool_call_completed")),
          ("tool_call_id", Json::string(call.id)),
          ("result", Json::string(result.content)),
          ("is_error", Json::boolean(is_error)),
        ]),
      )
    // ModelResponseReceived is the closest posoco gives us to a "message_end"
    // event: it fires once per non-streaming assistant message with the full
    // Message struct. We emit both `message_end` (for transcript append) and
    // a synthetic `model_invoked` (for token/usage rendering) so the UI has
    // both shapes without a second bridge.
    @posoco.TurnEvent::ModelResponseReceived(message~, usage~, ..) => {
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
          ("tool_call_id", Json::string(call.id)),
          ("tool_name", Json::string(call.name)),
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
        @posoco.StreamChunk::Usage(u) =>
          Json::object(
            Map::from_array([
              ("type", Json::string("model_invoked")),
              ("model", Json::string("")),
              ("usage", usage_to_json(Some(u))),
            ]),
          )
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

// ---------------------------------------------------------------------------
// JsUiPort — bridges structured UI intents and requests to the TS host.
// ---------------------------------------------------------------------------

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
/// The Promise must resolve to the strict `ui_response` JSON shape declared
/// in `src/events.ts`. Rejection is a host failure, never an implicit
/// cancellation.
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
    @port.UiBody::Progress(current~, label~) => {
      let fields : Array[(String, Json)] = [
        ("type", Json::string("progress")),
        ("current", Json::number(current)),
      ]
      match label {
        Some(value) => fields.push(("label", Json::string(value)))
        None => ()
      }
      Json::object(Map::from_array(fields))
    }
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
  let render_fields : Array[(String, Json)] = [
    ("slot", ui_slot_to_json(intent.slot)),
    ("key", Json::string(intent.key)),
    ("title", Json::string(intent.title)),
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
    @port.UiRequest::Input(prompt~, placeholder~) => {
      let fields : Array[(String, Json)] = [
        ("type", Json::string("input")),
        ("prompt", Json::string(prompt)),
      ]
      match placeholder {
        Some(value) => fields.push(("placeholder", Json::string(value)))
        None => ()
      }
      Json::object(Map::from_array(fields))
    }
    @port.UiRequest::Confirm(prompt~, default_yes~) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("confirm")),
          ("prompt", Json::string(prompt)),
          ("default_yes", Json::boolean(default_yes)),
        ]),
      )
    @port.UiRequest::Select(title~, options~, default_index~) => {
      let option_values : Array[Json] = []
      for option in options {
        option_values.push(Json::string(option))
      }
      let fields : Array[(String, Json)] = [
        ("type", Json::string("select")),
        ("title", Json::string(title)),
        ("options", Json::array(option_values)),
      ]
      match default_index {
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
  raise @error.UiError::HostError(message)
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
            @port.UiResponse::Selected(index=value.to_int())
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
    "unsupported" => raise @error.UiError::Unsupported
    "timeout" => raise @error.UiError::Timeout
    "host_error" => {
      let message = match fields.get("message") {
        Some(Json::String(value)) => value
        _ =>
          return invalid_ui_response(
            "ui_response host_error requires a string message",
          )
      }
      raise @error.UiError::HostError(message)
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
  { component_keys: [], autocomplete: [] }
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
        raise @error.UiError::HostError(
          "UI request callback rejected: \{err.to_string()}",
        )
    }
  decode_ui_response_event(response_json, request_id, req)
}

// ---------------------------------------------------------------------------
// CetasJsConfig — host-level configuration.
// ---------------------------------------------------------------------------

///|
/// Host configuration. All fields required and positional because MoonBit's
/// js backend exports optional/labeled args in a positional-but-flagged shape
/// that's awkward to call from TS. The TS host must always pass all 5 args
/// (use empty string / sensible default at the TS layer if needed).
/// Source: ffi.html — "#export_name is not available on functions with
/// optional arguments".
pub(all) struct CetasJsConfig {
  api_key : String
  base_url : String
  model : String
  cwd : String
  max_tool_rounds : Int
}

///|
/// Plain positional constructor — no labeled, no optional, no defaults.
pub fn CetasJsConfig::CetasJsConfig(
  api_key : String,
  base_url : String,
  model : String,
  cwd : String,
  max_tool_rounds : Int,
) -> CetasJsConfig {
  { api_key, base_url, model, cwd, max_tool_rounds }
}

// ---------------------------------------------------------------------------
// build_agent — composition.
// ---------------------------------------------------------------------------

///|
/// Long-lived cetas-js agent handle. The JS host constructs it once and reuses
/// it across turns so model adapters, UI correlation state, and the persistent
/// session store have one process lifetime.
pub(all) struct CetasJsAgent {
  agent : @posoco.Agent
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
) -> @js_async.Promise[CetasJsAgent] {
  @js_async.Promise::from_async() <| () => {
    let model = @cetas_core.build_default_model(
      config.api_key,
      config.base_url,
      config.model,
    )
    let (tools, prompt_contributors) = @cetas_core.build_default_features()
    let store = @fs_session.JsonlSessionStore::new(
      config.cwd + "/.cetas/sessions",
    )
    let observer = JsCallbackObserver::new(observer_callback)
    let ui = JsUiPort::new(render_callback, request_callback)
    let host_config : @cetas_core.CetasHostConfig = {
      cwd: config.cwd,
      max_tool_rounds: config.max_tool_rounds,
      temperature: None,
      max_output_tokens: None,
      tool_choice: None,
      reasoning_effort: None,
      model_context_window: None,
    }
    let agent = @cetas_core.build_agent_from_parts(
      model,
      tools,
      prompt_contributors,
      [],
      store,
      observer,
      ui,
      host_config,
    )
    { agent, }
  }
}

// ---------------------------------------------------------------------------
// Exports for TS host.
// ---------------------------------------------------------------------------

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
    @cetas_core.run_prompt(handle.agent, prompt, session_id)
  }
}

///|
/// Shut down the long-lived agent. Cleanup failures reject the returned
/// Promise and remain visible to the JS host.
pub fn cetas_js_shutdown(handle : CetasJsAgent) -> @js_async.Promise[Unit] {
  @js_async.Promise::from_async() <| () => { handle.agent.shutdown() }
}
