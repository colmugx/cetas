///|
/// Diagnostic retention for the native host's `EventHub` — explicitly opt-in.
///
/// The rolling wire log (`trace`) and the per-turn ledgers (`turn_traces` /
/// `turn_order`) exist so the trace page can show what the console said, turn by
/// turn. They are diagnostics, not the record: the history a user replays comes
/// from `session_transcript`, which reads the persisted session out of the
/// session catalog, and nothing in the realtime path polls a ledger
/// (`emit_out_of_band` frames skip both). Dropping a ledger row loses a trace
/// row, never a message.
///
/// Under the shared web contract one broadcast frame per turn fact is retained
/// for the lifetime of the process: a single long answer with thousands of text
/// deltas, or one oversized tool result, is kept in full. The native host is
/// exactly the long-lived process that makes that unbounded, so it can opt into
/// a budget here. The budget bounds the rolling log and the ledgers by
/// frame/event count *and* by serialized size, because a turn-count-only cap
/// misses the two shapes that actually grow: one turn with many deltas, and one
/// huge frame.
///
/// Two invariants hold under every budget:
///
/// - the wire is never trimmed: an attached sink still receives every frame
///   whole, and trimming only edits retained diagnostics;
/// - trimming is never silent: `retention_json` and `turn_retention_json` report
///   what was dropped, so a trace consumer can label a turn as trimmed instead
///   of presenting it as the complete path.

///|
/// One budget for both retention windows. Sizes are serialized frame lengths
/// (`Json::stringify().length()`), measured in UTF-16 code units, not bytes.
/// This is a deterministic retention budget, not a physical heap/RSS limit:
/// retained Json nodes, strings and containers have additional allocation
/// overhead, and UTF-8 wire size can differ.
///
/// Every field is a hard cap: newest frames win, the oldest are dropped, and a
/// single oversized frame can leave a window empty (reported, never silently
/// kept). The defaults retain at most 600 rolling frames / 1,048,576 serialized
/// code units, and 4,194,304 serialized code units across turn ledgers.
priv struct NativeTraceBudget {
  /// Frames kept in the rolling wire log.
  trace_frames : Int32
  /// Serialized size kept in the rolling wire log.
  trace_size : Int32
  /// Events kept per turn ledger.
  turn_events : Int32
  /// Serialized size kept per turn ledger.
  turn_size : Int32
  /// Turn ledgers kept per session, i.e. the `turn_order` window.
  session_turns : Int32
  /// Serialized size kept across every ledger of every session: the number of
  /// sessions in one process is unbounded, so per-session caps cannot bound it.
  total_size : Int32
}

///|
fn NativeTraceBudget::default() -> NativeTraceBudget {
  {
    trace_frames: 600,
    trace_size: 1024 * 1024,
    turn_events: 2048,
    turn_size: 256 * 1024,
    session_turns: 64,
    total_size: 4 * 1024 * 1024,
  }
}

///|
fn NativeTraceBudget::json(self : NativeTraceBudget) -> Json {
  Json::object(
    Map::from_array([
      ("trace_frames", Json::number(self.trace_frames.to_double())),
      ("trace_size", Json::number(self.trace_size.to_double())),
      ("turn_events", Json::number(self.turn_events.to_double())),
      ("turn_size", Json::number(self.turn_size.to_double())),
      ("session_turns", Json::number(self.session_turns.to_double())),
      ("total_size", Json::number(self.total_size.to_double())),
    ]),
  )
}

///|
/// Live accounting for one enabled budget: retained sizes, per-ledger creation
/// stamps and the drop counters the projection reports. It indexes the arrays
/// the hub already owns — no second store, no serialization of retained frames
/// beyond the frame being measured.
priv struct NativeRetention {
  budget : NativeTraceBudget
  mut trace_size : Int32
  mut ledger_size : Int32
  mut epoch : Int32
  mut dropped_frames : Int32
  mut dropped_events : Int32
  mut dropped_turns : Int32
  /// Serialized size per live ledger key (same key space as `turn_traces`).
  turn_sizes : Map[String, Int32]
  /// Events dropped per live ledger key.
  turn_dropped : Map[String, Int32]
  /// Creation stamp per live ledger key; global eviction takes the smallest.
  turn_epochs : Map[String, Int32]
}

///|
fn NativeRetention::new(budget : NativeTraceBudget) -> NativeRetention {
  {
    budget,
    trace_size: 0,
    ledger_size: 0,
    epoch: 0,
    dropped_frames: 0,
    dropped_events: 0,
    dropped_turns: 0,
    turn_sizes: Map([]),
    turn_dropped: Map([]),
    turn_epochs: Map([]),
  }
}

///|
fn native_frame_size(frame : Json) -> Int32 {
  frame.stringify().length()
}

///|
/// Session part of a ledger key. Key layout is `<session_id>/<turn_id>` and
/// session ids never contain `/`, so the first `/` is the divider.
fn native_key_session(key : String) -> String {
  match key.find("/") {
    Some(at) => key[:at].to_owned()
    None => key
  }
}

///|
/// Keep one broadcast frame on the rolling wire log, then trim it back to
/// budget: frame count first, then serialized size.
fn NativeRetention::keep_frame(
  self : NativeRetention,
  hub : EventHub,
  frame : Json,
) -> Unit {
  hub.trace.push(frame)
  self.trace_size += native_frame_size(frame)
  self.trim_trace(hub)
}

///|
/// Enforce the rolling-log window on whatever the hub currently retains.
fn NativeRetention::trim_trace(self : NativeRetention, hub : EventHub) -> Unit {
  while hub.trace.length() > self.budget.trace_frames ||
        (self.trace_size > self.budget.trace_size && hub.trace.length() > 0) {
    let oldest = hub.trace.remove(0)
    self.trace_size -= native_frame_size(oldest)
    self.dropped_frames += 1
  }
}

///|
/// Take over what the hub already retains, then bound it once. Enabling the
/// budget is therefore safe at any point — a second call, or a hub that already
/// emitted frames while composing: accounting starts from the real retained
/// content, never from zero, so the caps can not be silently exceeded.
fn NativeRetention::adopt(self : NativeRetention, hub : EventHub) -> Unit {
  for frame in hub.trace {
    self.trace_size += native_frame_size(frame)
  }
  // Seed in the hub's own turn order. Sessions iterate in map order, which only
  // decides how ties between equally old ledgers break during global eviction.
  for _, order in hub.turn_order {
    for key in order {
      match hub.turn_traces.get(key) {
        Some(ledger) => {
          self.epoch += 1
          self.turn_epochs[key] = self.epoch
          let mut size = 0
          for frame in ledger {
            size += native_frame_size(frame)
          }
          self.turn_sizes[key] = size
          self.ledger_size += size
        }
        None => ()
      }
    }
  }
  self.trim_trace(hub)
  self.trim_all(hub)
}

///|
/// Bound everything the hub retains right now: every ledger, every session's
/// turn window, then the process-wide total. Snapshot the keys first because
/// eviction edits the same maps and order lists.
fn NativeRetention::trim_all(self : NativeRetention, hub : EventHub) -> Unit {
  let keys : Array[String] = []
  for key, _ in hub.turn_traces {
    keys.push(key)
  }
  for key in keys {
    self.trim_ledger(hub, key)
  }
  let sessions : Array[String] = []
  for session_id, _ in hub.turn_order {
    sessions.push(session_id)
  }
  for session_id in sessions {
    self.trim_session(hub, session_id)
  }
  self.trim_total(hub)
}

///|
/// Start accounting for a freshly opened ledger — a turn, or the session's
/// orphan bucket for facts that arrive before the first accepted turn.
fn NativeRetention::track_ledger(
  self : NativeRetention,
  hub : EventHub,
  session_id : String,
  key : String,
  frame : Json,
) -> Unit {
  self.epoch += 1
  self.turn_epochs[key] = self.epoch
  let size = native_frame_size(frame)
  self.turn_sizes[key] = size
  self.ledger_size += size
  self.trim_ledger(hub, key)
  self.trim_session(hub, session_id)
  self.trim_total(hub)
}

///|
/// Keep one frame in an already-open ledger, then trim it back to budget.
fn NativeRetention::keep_ledger_event(
  self : NativeRetention,
  hub : EventHub,
  key : String,
  frame : Json,
) -> Unit {
  let size = native_frame_size(frame)
  self.turn_sizes[key] = self.turn_sizes.get_or_default(key, 0) + size
  self.ledger_size += size
  self.trim_ledger(hub, key)
  self.trim_total(hub)
}

///|
/// Per-ledger window: event count, then serialized size. Newest events win, so
/// a turn that streams thousands of deltas keeps its ending rather than a head
/// no consumer can follow.
///
/// The size cap is the smaller of the turn budget and the whole-hub budget: one
/// ledger can never need more than the process-wide window, and capping it here
/// means the newest turn keeps a bounded tail instead of being evicted whole by
/// `trim_total`.
fn NativeRetention::trim_ledger(
  self : NativeRetention,
  hub : EventHub,
  key : String,
) -> Unit {
  let cap = if self.budget.turn_size < self.budget.total_size {
    self.budget.turn_size
  } else {
    self.budget.total_size
  }
  match hub.turn_traces.get(key) {
    Some(ledger) =>
      while ledger.length() > self.budget.turn_events ||
            (
              self.turn_sizes.get_or_default(key, 0) > cap &&
              ledger.length() > 0
            ) {
        let oldest = ledger.remove(0)
        let size = native_frame_size(oldest)
        self.turn_sizes[key] = self.turn_sizes.get_or_default(key, 0) - size
        self.ledger_size -= size
        self.turn_dropped[key] = self.turn_dropped.get_or_default(key, 0) + 1
        self.dropped_events += 1
      }
    None => ()
  }
}

///|
/// Per-session window: drop whole turns, oldest first, so `turn_order` and the
/// ledgers it indexes stay bounded for one session.
fn NativeRetention::trim_session(
  self : NativeRetention,
  hub : EventHub,
  session_id : String,
) -> Unit {
  match hub.turn_order.get(session_id) {
    Some(order) =>
      while order.length() > self.budget.session_turns && order.length() > 0 {
        // `forget_ledger` removes the key from this same array.
        self.forget_ledger(hub, order[0])
        self.dropped_turns += 1
      }
    None => ()
  }
}

///|
/// Process-wide window: drop whole ledgers, globally oldest first, until the
/// retained ledger bytes fit. One rare scan per eviction, and evictions only
/// happen while over budget.
///
/// The newest turn is never the victim: `trim_ledger` already capped it at
/// `min(turn_size, total_size)`, so the loop always terminates with a live
/// ledger rather than an empty trace.
fn NativeRetention::trim_total(self : NativeRetention, hub : EventHub) -> Unit {
  while self.ledger_size > self.budget.total_size && !hub.turn_traces.is_empty() {
    self.forget_ledger(hub, self.oldest_ledger_key(hub))
    self.dropped_turns += 1
  }
}

///|
fn NativeRetention::oldest_ledger_key(
  self : NativeRetention,
  hub : EventHub,
) -> String {
  let mut oldest = ""
  let mut oldest_epoch = 0
  let mut first = true
  for key, _ in hub.turn_traces {
    let epoch = self.turn_epochs.get_or_default(key, 0)
    if first || epoch < oldest_epoch {
      first = false
      oldest = key
      oldest_epoch = epoch
    }
  }
  oldest
}

///|
/// Drop one ledger and everything that indexes it: the ledger, its slot in the
/// session's turn order, its size, its creation stamp and its drop count. An
/// emptied session leaves `turn_order` entirely, so the projection never
/// renders a session that retains nothing.
fn NativeRetention::forget_ledger(
  self : NativeRetention,
  hub : EventHub,
  key : String,
) -> Unit {
  ignore(hub.turn_traces.remove_and_get(key))
  let session_id = native_key_session(key)
  match hub.turn_order.get(session_id) {
    Some(order) => {
      let mut at = -1
      for index in 0..<order.length() {
        if order[index] == key {
          at = index
        }
      }
      if at >= 0 {
        ignore(order.remove(at))
      }
      if order.is_empty() {
        hub.turn_order.remove(session_id)
      }
    }
    None => ()
  }
  self.ledger_size -= self.turn_sizes.get_or_default(key, 0)
  self.turn_sizes.remove(key)
  self.turn_epochs.remove(key)
  self.turn_dropped.remove(key)
}

///|
fn NativeRetention::json(self : NativeRetention, hub : EventHub) -> Json {
  let trimmed = self.dropped_frames > 0 ||
    self.dropped_events > 0 ||
    self.dropped_turns > 0
  Json::object(
    Map::from_array([
      ("enabled", Json::boolean(true)),
      ("trimmed", Json::boolean(trimmed)),
      ("budget", self.budget.json()),
      (
        "trace",
        Json::object(
          Map::from_array([
            ("retained_frames", Json::number(hub.trace.length().to_double())),
            ("retained_size", Json::number(self.trace_size.to_double())),
            ("dropped_frames", Json::number(self.dropped_frames.to_double())),
          ]),
        ),
      ),
      (
        "ledgers",
        Json::object(
          Map::from_array([
            (
              "retained_turns",
              Json::number(hub.turn_traces.length().to_double()),
            ),
            ("retained_size", Json::number(self.ledger_size.to_double())),
            ("dropped_events", Json::number(self.dropped_events.to_double())),
            ("dropped_turns", Json::number(self.dropped_turns.to_double())),
          ]),
        ),
      ),
    ]),
  )
}

///|
/// Opt the hub into the native diagnostic budget. Call it once, immediately
/// after the hub exists and before frames are emitted (both composition points
/// — `compose_console_runtime` and `console_bootstrap` — create the hub, so the
/// same `native_ui` flag that gates the projection gates this window).
///
/// Enabling later is still safe: the window adopts whatever the hub already
/// retains and bounds it right away, so a late (or repeated) call can never
/// leave the caps silently exceeded.
///
/// Off (the default for every console/web host) keeps the shared contract
/// exactly: a 600-frame rolling log by count and complete per-turn ledgers.
fn EventHub::enable_native_retention(
  self : EventHub,
  budget~ : NativeTraceBudget = NativeTraceBudget::default(),
) -> Unit {
  let retention = NativeRetention::new(budget)
  retention.adopt(self)
  self.retention = Some(retention)
}

///|
/// Whole-hub trim report for the trace projection: explicit `enabled` /
/// `trimmed` flags plus retained and dropped counters, so a consumer can tell a
/// complete trace from a trimmed one instead of claiming the former.
fn EventHub::retention_json(self : EventHub) -> Json {
  match self.retention {
    Some(retention) => retention.json(self)
    None =>
      Json::object(
        Map::from_array([
          ("enabled", Json::boolean(false)),
          ("trimmed", Json::boolean(false)),
        ]),
      )
  }
}

///|
/// Per-turn trim report. `trimmed` is false with zero drops when nothing was
/// evicted — including every default web hub, which retains whole ledgers.
fn EventHub::turn_retention_json(self : EventHub, key : String) -> Json {
  let retained = match self.turn_traces.get(key) {
    Some(ledger) => ledger.length()
    None => 0
  }
  let dropped = match self.retention {
    Some(retention) => retention.turn_dropped.get_or_default(key, 0)
    None => 0
  }
  Json::object(
    Map::from_array([
      ("retained_events", Json::number(retained.to_double())),
      ("dropped_events", Json::number(dropped.to_double())),
      ("trimmed", Json::boolean(dropped > 0)),
    ]),
  )
}
