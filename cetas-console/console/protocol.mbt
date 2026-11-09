///|
/// Shared event channel: one sink per WebSocket connection and one global
/// sequence, so events from concurrent sessions interleave coherently.
struct EventHub {
  mut sink : ((String) -> Unit)?
  mut seq : Int32
  /// Rolling wire log of broadcast events, newest last (capped).
  trace : Array[Json]
  /// Per-turn event ledgers, keyed by "session/turn"; the trace view reads
  /// these instead of the raw wire log.
  turn_traces : Map[String, Array[Json]]
  /// Turn keys per session, in creation order.
  turn_order : Map[String, Array[String]]
  /// Native-only diagnostic budget; `None` is the shared web contract (see
  /// console/native_trace_budget.mbt). Opt in with `enable_native_retention`,
  /// which bounds both the rolling log and the ledgers while leaving the wire
  /// and the persisted history untouched.
  mut retention : NativeRetention?
  mut startup_warnings_flushed : Bool
}

///|
fn EventHub::new() -> EventHub {
  {
    sink: None,
    seq: 0,
    trace: [],
    turn_traces: Map([]),
    turn_order: Map([]),
    retention: None,
    startup_warnings_flushed: false,
  }
}

///|
fn EventHub::attach(self : EventHub, sink : (String) -> Unit) -> Unit {
  self.sink = Some(sink)
  // Platform construction can warn before the host attaches its UI sink.
  // Native terminals must not write around their renderer. Reuse the bounded
  // rolling trace rather than retaining a second startup-only message queue.
  if self.retention is Some(_) && !self.startup_warnings_flushed {
    self.startup_warnings_flushed = true
    for frame in self.trace {
      if frame is { "type": Json::String("config.warning"), .. } {
        sink(frame.stringify())
      }
    }
  }
}

///|
fn EventHub::native_warning(
  self : EventHub,
  session_id : String,
  text : String,
) -> Unit {
  self.emit(session_id, "", "config.warning", extra=[
    ("field", Json::string("runtime")),
    ("value", Json::string("")),
    ("reason", Json::string(text)),
  ])
}

///|
fn EventHub::detach(self : EventHub) -> Unit {
  self.sink = None
}

///|
/// Stamp one frame with the global sequence, attribution and timestamp. Every
/// wire fact — recorded or out-of-band — goes through this so consumers keep
/// one monotonic ordering.
fn EventHub::next_frame(
  self : EventHub,
  session_id : String,
  turn_id : String,
  event_type : String,
  extra : Array[(String, Json)],
) -> Json {
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
  Json::object(Map::from_array(fields))
}

///|
fn EventHub::emit(
  self : EventHub,
  session_id : String,
  turn_id : String,
  event_type : String,
  extra~ : Array[(String, Json)] = [],
  broadcast~ : Bool = true,
) -> Unit {
  let framed = self.next_frame(session_id, turn_id, event_type, extra)
  if broadcast {
    self.keep_wire_frame(framed)
  }
  if turn_id != "" && session_id != "" {
    let key = session_id + "/" + turn_id
    match self.turn_traces.get(key) {
      Some(_) => self.append_ledger_event(key, framed)
      None =>
        if event_type == "turn.accepted" {
          self.open_ledger(session_id, key, framed, head=false)
        } else {
          // Events before an accepted turn (snapshots, redirects) stay
          // session-scoped orphans rather than inventing a turn.
          let orphan_key = session_id + "/"
          match self.turn_traces.get(orphan_key) {
            Some(_) => self.append_ledger_event(orphan_key, framed)
            None => self.open_ledger(session_id, orphan_key, framed, head=true)
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
/// Retain one broadcast frame on the rolling wire log. The default path is the
/// shared web contract — the newest 600 frames by count; a native retention
/// window bounds the same log by size as well.
fn EventHub::keep_wire_frame(self : EventHub, framed : Json) -> Unit {
  match self.retention {
    Some(retention) => retention.keep_frame(self, framed)
    None => {
      self.trace.push(framed)
      if self.trace.length() > 600 {
        ignore(self.trace.remove(0))
      }
    }
  }
}

///|
/// Open the ledger for one turn (or for the session's orphan bucket, which
/// stays in front of the turn list so it keeps rendering first).
fn EventHub::open_ledger(
  self : EventHub,
  session_id : String,
  key : String,
  framed : Json,
  head~ : Bool,
) -> Unit {
  let ledger : Array[Json] = [framed]
  self.turn_traces[key] = ledger
  match self.turn_order.get(session_id) {
    Some(order) => if head { order.insert(0, key) } else { order.push(key) }
    None => self.turn_order[session_id] = [key]
  }
  match self.retention {
    Some(retention) => retention.track_ledger(self, session_id, key, framed)
    None => ()
  }
}

///|
fn EventHub::append_ledger_event(
  self : EventHub,
  key : String,
  framed : Json,
) -> Unit {
  match self.turn_traces.get(key) {
    Some(ledger) => {
      ledger.push(framed)
      match self.retention {
        Some(retention) => retention.keep_ledger_event(self, key, framed)
        None => ()
      }
    }
    None => ()
  }
}

///|
/// Fan out one realtime-only frame: the sink sees it, the rolling wire log and
/// the per-turn ledgers do not. Nested child runs and non-blocking questions
/// are session facts, not transcript rows, so a native consumer can render
/// them in an activity region without any risk of them entering the parent
/// transcript or the trace page. `turn_id` is empty by construction — there is
/// no parent turn to attribute them to.
fn EventHub::emit_out_of_band(
  self : EventHub,
  session_id : String,
  event_type : String,
  extra~ : Array[(String, Json)] = [],
) -> Unit {
  let framed = self.next_frame(session_id, "", event_type, extra)
  match self.sink {
    Some(sink) => sink(framed.stringify())
    None => ()
  }
}

///|
/// Per-session observer: translates posoco turn events into protocol events
/// attributed to its own session and turn. One instance per composed agent.
priv struct ConsoleObserver {
  hub : EventHub
  session_id : String
  mut turn_id : String
  /// Host-label publisher capability on the session event system: harness
  /// counters are published as typed status ops through it. None means the
  /// session is retiring; the counters then publish nowhere.
  events : @posoco.Events?
  /// Protocol tag carried on session.snapshot frames ("cetas-web/0.1").
  protocol : String
  /// Explicit opt-in for the native terminal host's realtime projection. Off
  /// keeps the shared web wire contract byte-for-byte: no lifecycle phase, no
  /// streamed tool arguments, no ledger-only broadcasts.
  native_ui : Bool
  mut turn_count : Int32
  mut step_count : Int32
}

///|
fn ConsoleObserver::new(
  hub : EventHub,
  events : @posoco.Events?,
  session_id : String,
  protocol : String,
  native_ui~ : Bool = false,
) -> ConsoleObserver {
  {
    hub,
    events,
    session_id,
    turn_id: "",
    protocol,
    native_ui,
    turn_count: 0,
    step_count: 0,
  }
}

///|
fn ConsoleObserver::emit(
  self : ConsoleObserver,
  event_type : String,
  extra~ : Array[(String, Json)] = [],
  broadcast~ : Bool = true,
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
/// Cumulative harness counters surfaced on the statusbar via the typed status
/// ops — same channel every peer uses.
fn ConsoleObserver::publish_turn_count(self : ConsoleObserver) -> Unit {
  self.publish_status_update("turns", self.turn_count.to_string())
}

///|
fn ConsoleObserver::publish_step_count(self : ConsoleObserver) -> Unit {
  self.publish_status_update("steps", self.step_count.to_string())
}

///|
/// Publish one counter update as a typed `StatusChanged` op. Fire-and-forget:
/// a closed channel only means the session is retiring.
fn ConsoleObserver::publish_status_update(
  self : ConsoleObserver,
  segment : String,
  value : String,
) -> Unit {
  match self.events {
    Some(events) =>
      ignore(
        events.publish(
          @kit_events.StatusChanged(@kit_events.Update(segment~, value~)),
        ),
      )
    None => ()
  }
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
  scope : @posoco.EventScope?,
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
        // Streamed tool-call arguments: fragments concatenate into the full
        // arguments JSON string and always precede `tool.started`. The web
        // host accumulates assistant text only, so it stays opted out.
        @posoco.StreamChunk::ToolCallDelta(index~, id~, name~, arguments_delta~) =>
          if self.native_ui {
            self.emit("tool.args_delta", extra=[
              ("index", Json::number(index.to_double())),
              ("id", native_json_string_opt(id)),
              ("name", native_json_string_opt(name)),
              ("delta", native_json_string_opt(arguments_delta)),
            ])
          }
        _ => ()
      }
    @posoco.TurnEvent::ToolCallPending(call) => {
      self.step_count += 1
      self.publish_step_count()
      let extra : Array[(String, Json)] = [
        ("tool_call_id", Json::string(call.call_id.to_string())),
        ("tool_name", Json::string(call.name.to_string())),
        ("arguments", call.arguments),
      ]
      if self.native_ui {
        extra.push(("phase", Json::string("pending")))
      }
      self.emit("tool.started", extra~)
    }
    @posoco.TurnEvent::ToolCallSucceeded(
      call~,
      content~,
      structured~,
      attachments~
    ) => {
      let extra : Array[(String, Json)] = [
        ("tool_call_id", Json::string(call.call_id.to_string())),
        ("tool_name", Json::string(call.name.to_string())),
        ("result", Json::string(content)),
        ("is_error", Json::boolean(false)),
      ]
      if self.native_ui {
        extra.push(("phase", Json::string("succeeded")))
        extra.push(
          (
            "structured",
            match structured {
              Some(value) => value
              None => Json::null()
            },
          ),
        )
        extra.push(
          ("attachments", Json::array(native_attachment_json(attachments))),
        )
      }
      self.emit("tool.completed", extra~)
    }
    @posoco.TurnEvent::ToolCallFailed(call~, failure~) => {
      let (result, failure_kind, category, structured) = match failure {
        ReportedError(content~, structured~) =>
          (content, "reported_error", "", structured)
        Runtime(category~, message~) =>
          ("\{category}: \{message}", "runtime", category, None)
      }
      let extra : Array[(String, Json)] = [
        ("tool_call_id", Json::string(call.call_id.to_string())),
        ("tool_name", Json::string(call.name.to_string())),
        ("result", Json::string(result)),
        ("is_error", Json::boolean(true)),
      ]
      if self.native_ui {
        extra.push(("phase", Json::string("failed")))
        extra.push(("failure_kind", Json::string(failure_kind)))
        extra.push(("error_category", Json::string(category)))
        extra.push(
          (
            "structured",
            match structured {
              Some(value) => value
              None => Json::null()
            },
          ),
        )
        extra.push(("attachments", Json::array(native_attachment_json([]))))
      }
      self.emit("tool.completed", extra~)
    }
    @posoco.TurnEvent::ToolCallRejected(call~, reason~) => {
      let reason_text = reason.to_string()
      let extra : Array[(String, Json)] = [
        ("tool_call_id", Json::string(call.call_id.to_string())),
        ("tool_name", Json::string(call.name.to_string())),
        ("result", Json::string(reason_text)),
        ("is_error", Json::boolean(true)),
      ]
      if self.native_ui {
        extra.push(("phase", Json::string("rejected")))
        extra.push(("reason", Json::string(reason_text)))
        extra.push(("structured", Json::null()))
        extra.push(("attachments", Json::array(native_attachment_json([]))))
      }
      self.emit("tool.completed", extra~)
    }
    @posoco.TurnEvent::ToolCallAbandoned(call~, reason~) => {
      let extra : Array[(String, Json)] = [
        ("tool_call_id", Json::string(call.call_id.to_string())),
        ("tool_name", Json::string(call.name.to_string())),
        ("result", Json::string(reason)),
        ("is_error", Json::boolean(true)),
      ]
      if self.native_ui {
        extra.push(("phase", Json::string("abandoned")))
        extra.push(("reason", Json::string(reason)))
        extra.push(("structured", Json::null()))
        extra.push(("attachments", Json::array(native_attachment_json([]))))
      }
      self.emit("tool.completed", extra~)
    }
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
    @posoco.TurnEvent::ToolCallApproved(call~, consent_scope~) => {
      let extra : Array[(String, Json)] = [
        ("tool_call_id", Json::string(call.call_id.to_string())),
        ("tool_name", Json::string(call.name.to_string())),
        (
          "consent_scope",
          match consent_scope {
            Some(scope) => Json::string(scope)
            None => Json::null()
          },
        ),
      ]
      if self.native_ui {
        extra.push(("phase", Json::string("approved")))
      }
      self.emit("tool.approved", extra~)
    }
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
    @posoco.TurnEvent::ToolCallStarted(call~) => {
      let extra : Array[(String, Json)] = [
        ("tool_call_id", Json::string(call.call_id.to_string())),
      ]
      if self.native_ui {
        extra.push(("tool_name", Json::string(call.name.to_string())))
        extra.push(("arguments", call.arguments))
        extra.push(("phase", Json::string("started")))
      }
      self.emit("tool.started_run", extra~, broadcast=self.native_ui)
    }
    @posoco.TurnEvent::StreamChunksDropped(count~) =>
      self.emit(
        "stream.dropped",
        extra=[("count", Json::number(count.to_double()))],
        broadcast=self.native_ui,
      )
    @posoco.TurnEvent::ConfigWarning(field~, value~, reason~) =>
      self.emit(
        "config.warning",
        extra=[
          ("field", Json::string(field)),
          ("value", Json::string(value)),
          ("reason", Json::string(reason)),
        ],
        broadcast=self.native_ui,
      )
    @posoco.TurnEvent::ConfigChanged(field~, old_value~, new_value~) =>
      self.emit(
        "config.changed",
        extra=[
          ("field", Json::string(field)),
          ("old_value", Json::string(old_value)),
          ("new_value", Json::string(new_value)),
        ],
        broadcast=self.native_ui,
      )
    @posoco.TurnEvent::OperationFinalized(operation~, outcome~, detail~) =>
      self.emit(
        "operation.finalized",
        extra=[
          ("operation", Json::string(operation)),
          ("outcome", Json::string(outcome)),
          ("detail", Json::string(detail)),
        ],
        broadcast=self.native_ui,
      )
    // Extension/child-run facts. Natively the subagent and activity surfaces
    // need the source, the event scope and the call/child attribution; the
    // web host renders subagents from its own envelopes instead.
    @posoco.TurnEvent::Custom(source~, label~, data~) => {
      let extra : Array[(String, Json)] = [
        ("source", Json::string(source)),
        ("label", Json::string(label)),
        ("data", data),
      ]
      if self.native_ui {
        extra.push(("scope", native_event_scope_json(scope)))
        extra.push(
          (
            "parent_call",
            Json::string(native_json_string_field(data, "parent_call")),
          ),
        )
        extra.push(
          (
            "child_session",
            Json::string(native_json_string_field(data, "child_session")),
          ),
        )
      }
      self.emit("custom", extra~, broadcast=self.native_ui)
    }
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
