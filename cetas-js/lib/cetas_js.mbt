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
fn turn_event_to_json(event : @posoco.TurnEvent) -> String {
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
        _ =>
          // ToolCallDelta / Finish — surface as stream_chunk so the UI can
          // log without acting. Arguments deltas aren't actionable until the
          // call resolves to a ToolCallPending.
          Json::object(
            Map::from_array([
              ("type", Json::string("stream_chunk")),
              ("raw", Json::string("")),
            ]),
          )
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
  json.stringify()
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
  let parsed : Json = @json.parse(turn_event_to_json(event)) catch {
    _ => return // unreachable — we just stringify'd a Json value
  }
  match parsed {
    Json::Array(items) =>
      for item in items {
        self.callback.invoke(item.stringify())
      }
    single => self.callback.invoke(single.stringify())
  }
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
/// Build the cetas-js agent with a given JS observer callback.
///
/// Delegates model/tool construction to `cetas_core::build_default_*` so the
/// same ext-* set runs on both cetas-native and cetas-js. The cwd is unused
/// for now (was previously a BunBashTool field); bash runs in the host's
/// process cwd by default.
pub fn build_agent(
  config : CetasJsConfig,
  observer_callback : JsCallback,
) -> @posoco.Agent raise @posoco.CompositionError {
  let model = @cetas_core.build_default_model(
    config.api_key,
    config.base_url,
    config.model,
  )
  let tools = @cetas_core.build_default_tools()
  let store = @cetas_core.InMemorySessionStore::new()
  let observer = JsCallbackObserver::new(observer_callback)
  let host_config : @cetas_core.CetasHostConfig = {
    max_tool_rounds: config.max_tool_rounds,
    temperature: None,
    max_output_tokens: None,
    tool_choice: None,
    reasoning_effort: None,
    model_context_window: None,
  }
  @cetas_core.build_agent_from_parts(model, tools, store, observer, host_config)
}

// ---------------------------------------------------------------------------
// Exports for TS host.
// ---------------------------------------------------------------------------

///|
/// Build an agent and run a single turn, returning a JS Promise that resolves
/// to the assistant's text reply.
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
  config : CetasJsConfig,
  observer_callback : JsCallback,
  prompt : String,
  session_id : String,
) -> @js_async.Promise[String] {
  // Closure captures config/observer_callback/prompt/session_id from the
  // enclosing fn. The lambda's type is inferred as `async () -> String`
  // because `run_prompt` is `async fn`.
  @js_async.Promise::from_async() <| () => {
    let agent = build_agent(config, observer_callback)
    @cetas_core.run_prompt(agent, prompt, session_id)
  }
}
