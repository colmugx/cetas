///|
/// Shared event channel: one sink per WebSocket connection and one global
/// sequence, so events from concurrent sessions interleave coherently.
struct EventHub {
  mut sink : ((String) -> Unit)?
  mut seq : Int
  /// Rolling wire log of broadcast events, newest last (capped).
  trace : Array[Json]
  /// Per-turn event ledgers, keyed by "session/turn"; the trace view reads
  /// these instead of the raw wire log.
  turn_traces : Map[String, Array[Json]]
  /// Turn keys per session, in creation order.
  turn_order : Map[String, Array[String]]
}

///|
fn EventHub::new() -> EventHub {
  { sink: None, seq: 0, trace: [], turn_traces: Map([]), turn_order: Map([]), }
}

///|
fn EventHub::attach(self : EventHub, sink : (String) -> Unit) -> Unit {
  self.sink = Some(sink)
}

///|
fn EventHub::detach(self : EventHub) -> Unit {
  self.sink = None
}

///|
fn EventHub::emit(
  self : EventHub,
  session_id : String,
  turn_id : String,
  event_type : String,
  extra? : Array[(String, Json)] = [],
  broadcast? : Bool = true,
) -> Unit {
  self.seq += 1
  let fields : Array[(String, Json)] = [
    ("type", Json::string(event_type)),
    ("seq", Json::number(self.seq.to_double())),
    ("event_id", Json::string("e-" + self.seq.to_string())),
    ("session_id", Json::string(session_id)),
    ("turn_id", Json::string(turn_id)),
  ]
  for field in extra {
    fields.push(field)
  }
  fields.push(("ts", Json::number(@async.now().to_double())))
  let framed = Json::object(Map::from_array(fields))
  if broadcast {
    self.trace.push(framed)
    if self.trace.length() > 600 {
      ignore(self.trace.remove(0))
    }
  }
  if turn_id != "" && session_id != "" {
    let key = session_id + "/" + turn_id
    match self.turn_traces.get(key) {
      Some(ledger) => {
        ledger.push(framed)
        ignore(self.trace.length())
      }
      None =>
        if event_type == "turn.accepted" {
          let ledger : Array[Json] = [framed]
          self.turn_traces[key] = ledger
          match self.turn_order.get(session_id) {
            Some(order) => order.push(key)
            None => self.turn_order[session_id] = [key]
          }
        } else {
          // Events before an accepted turn (snapshots, redirects) stay
          // session-scoped orphans rather than inventing a turn.
          let orphan_key = session_id + "/"
          match self.turn_traces.get(orphan_key) {
            Some(ledger) => ledger.push(framed)
            None => {
              let ledger : Array[Json] = [framed]
              self.turn_traces[orphan_key] = ledger
              match self.turn_order.get(session_id) {
                Some(order) => order.insert(0, orphan_key)
                None => self.turn_order[session_id] = [orphan_key]
              }
            }
          }
        }
    }
  }
  if broadcast {
    match self.sink {
      Some(sink) => sink(framed.stringify())
      None => ()
    }
  }
}

///|
/// Per-session observer: translates posoco turn events into protocol events
/// attributed to its own session and turn. One instance per composed agent.
priv struct ConsoleObserver {
  hub : EventHub
  session_id : String
  mut turn_id : String
  bus : @devkit.EventBus
  /// Host tag: console log/status attribution ("cetas-web", "cetas-desktop").
  label : String
  /// Protocol tag carried on session.snapshot frames ("cetas-web/0.1").
  protocol : String
  mut turn_count : Int
  mut step_count : Int
}

///|
fn ConsoleObserver::new(
  hub : EventHub,
  bus : @devkit.EventBus,
  session_id : String,
  label : String,
  protocol : String,
) -> ConsoleObserver {
  {
    hub,
    bus,
    session_id,
    turn_id: "",
    label,
    protocol,
    turn_count: 0,
    step_count: 0,
  }
}

///|
fn ConsoleObserver::emit(
  self : ConsoleObserver,
  event_type : String,
  extra? : Array[(String, Json)] = [],
  broadcast? : Bool = true,
) -> Unit {
  self.hub.emit(self.session_id, self.turn_id, event_type, extra~, broadcast~)
}

///|
fn ConsoleObserver::begin_turn(
  self : ConsoleObserver,
  turn_id : String,
) -> Unit {
  self.turn_id = turn_id
  self.turn_count += 1
  self.publish_turn_count()
}

///|
/// Cumulative harness counters surfaced on the statusbar via the devkit
/// status ops — same publish path every peer uses.
fn ConsoleObserver::publish_turn_count(self : ConsoleObserver) -> Unit {
  @devkit.publish_status_update(
    self.bus,
    source=self.label,
    segment="turns",
    value=self.turn_count.to_string(),
  )
}

///|
fn ConsoleObserver::publish_step_count(self : ConsoleObserver) -> Unit {
  @devkit.publish_status_update(
    self.bus,
    source=self.label,
    segment="steps",
    value=self.step_count.to_string(),
  )
}

///|
fn ConsoleObserver::emit_snapshot(
  self : ConsoleObserver,
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
    ("protocol", Json::string(self.protocol)),
  ])
}

///|
fn ConsoleObserver::emit_turn_accepted(
  self : ConsoleObserver,
  prompt : String,
) -> Unit {
  self.emit("turn.accepted", extra=[("prompt", Json::string(prompt))])
}

///|
fn ConsoleObserver::emit_turn_completed(
  self : ConsoleObserver,
  text : String,
) -> Unit {
  self.emit("turn.completed", extra=[("text", Json::string(text))])
}

///|
fn ConsoleObserver::emit_turn_failed(
  self : ConsoleObserver,
  message : String,
) -> Unit {
  self.emit("turn.failed", extra=[("message", Json::string(message))])
}

///|
fn ConsoleObserver::emit_abort_result(
  self : ConsoleObserver,
  outcome : String,
) -> Unit {
  self.emit("turn.abort_result", extra=[("outcome", Json::string(outcome))])
}

///|
impl @posoco.Observer for ConsoleObserver with fn on_event(
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
    @posoco.TurnEvent::ToolCallPending(call) => {
      self.step_count += 1
      self.publish_step_count()
      self.emit("tool.started", extra=[
        ("tool_call_id", Json::string(call.call_id.to_string())),
        ("tool_name", Json::string(call.name.to_string())),
        ("arguments", call.arguments),
      ])
    }
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
    @posoco.TurnEvent::SessionRedirect(from~, to~, ..) =>
      self.emit("session.redirect", extra=[
        ("from", Json::string(from)),
        ("to", Json::string(to)),
      ])
    @posoco.TurnEvent::ModelResponseReceived(usage~, ..) =>
      match usage {
        Some(usage) =>
          self.emit("usage.delta", extra=[
            (
              "input_tokens",
              match usage.input_tokens {
                Some(value) => Json::number(value.to_double())
                None => Json::null()
              },
            ),
            (
              "output_tokens",
              match usage.output_tokens {
                Some(value) => Json::number(value.to_double())
                None => Json::null()
              },
            ),
            (
              "total_tokens",
              match usage.total_tokens {
                Some(value) => Json::number(value.to_double())
                None => Json::null()
              },
            ),
            (
              "cached_input_tokens",
              match usage.cached_input_tokens {
                Some(value) => Json::number(value.to_double())
                None => Json::null()
              },
            ),
          ])
        None => ()
      }
    @posoco.TurnEvent::ContextStateUpdated(state~) =>
      self.emit("context.state", extra=[
        (
          "measured_tokens",
          match state.last_measured_tokens {
            Some(value) => Json::number(value.to_double())
            None => Json::null()
          },
        ),
        (
          "window_tokens",
          match state.window_tokens {
            Some(value) => Json::number(value.to_double())
            None => Json::null()
          },
        ),
        ("compact_threshold", Json::number(state.compact_threshold)),
        ("context_version", Json::number(state.context_version.to_double())),
        (
          "reading_message_count",
          Json::number(state.reading_message_count.to_double()),
        ),
      ])
    @posoco.TurnEvent::ToolCallApproved(call~, consent_scope~) =>
      self.emit("tool.approved", extra=[
        ("tool_call_id", Json::string(call.call_id.to_string())),
        ("tool_name", Json::string(call.name.to_string())),
        (
          "consent_scope",
          match consent_scope {
            Some(scope) => Json::string(scope)
            None => Json::null()
          },
        ),
      ])
    @posoco.TurnEvent::CompactStarted(trigger~) =>
      self.emit("compact.started", extra=[("trigger", Json::string(trigger))])
    @posoco.TurnEvent::CompactFinished(trigger~, mode~, final_session_id~, ..) =>
      self.emit("compact.finished", extra=[
        ("trigger", Json::string(trigger)),
        ("mode", Json::string(mode)),
        ("final_session_id", Json::string(final_session_id)),
      ])
    // Internal lifecycle events ride the per-turn ledger without touching
    // the wire transcript.
    @posoco.TurnEvent::UserRequestStarted(kind~, prompt~) =>
      self.emit(
        "user.request_started",
        extra=[("kind", Json::string(kind)), ("prompt", Json::string(prompt))],
        broadcast=false,
      )
    @posoco.TurnEvent::UserRequestFinished(kind~, outcome~) =>
      self.emit(
        "user.request_finished",
        extra=[("kind", Json::string(kind)), ("outcome", Json::string(outcome))],
        broadcast=false,
      )
    @posoco.TurnEvent::ToolCallStarted(call~) =>
      self.emit(
        "tool.started_run",
        extra=[("tool_call_id", Json::string(call.call_id.to_string()))],
        broadcast=false,
      )
    @posoco.TurnEvent::StreamChunksDropped(count~) =>
      self.emit(
        "stream.dropped",
        extra=[("count", Json::number(count.to_double()))],
        broadcast=false,
      )
    @posoco.TurnEvent::ConfigWarning(field~, value~, reason~) =>
      self.emit(
        "config.warning",
        extra=[
          ("field", Json::string(field)),
          ("value", Json::string(value)),
          ("reason", Json::string(reason)),
        ],
        broadcast=false,
      )
    @posoco.TurnEvent::ConfigChanged(field~, old_value~, new_value~) =>
      self.emit(
        "config.changed",
        extra=[
          ("field", Json::string(field)),
          ("old_value", Json::string(old_value)),
          ("new_value", Json::string(new_value)),
        ],
        broadcast=false,
      )
    @posoco.TurnEvent::OperationFinalized(operation~, outcome~, detail~) =>
      self.emit(
        "operation.finalized",
        extra=[
          ("operation", Json::string(operation)),
          ("outcome", Json::string(outcome)),
          ("detail", Json::string(detail)),
        ],
        broadcast=false,
      )
    @posoco.TurnEvent::Custom(source~, label~, data~) =>
      self.emit(
        "custom",
        extra=[
          ("source", Json::string(source)),
          ("label", Json::string(label)),
          ("data", data),
        ],
        broadcast=false,
      )
    _ => ()
  }
}

///|
impl @posoco.Extension for ConsoleObserver with fn extension_id(
  _self : ConsoleObserver,
) -> String {
  "cetas_web_observer"
}

///|
impl @posoco.Extension for ConsoleObserver with fn manifest(
  self : ConsoleObserver,
) -> @posoco.ExtensionManifest {
  let manifest = @posoco.ExtensionManifest::default(id="cetas_web_observer")
  { ..manifest, observers: [self], }
}
