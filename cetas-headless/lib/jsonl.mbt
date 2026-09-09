///|
/// jsonl.mbt — the `--jsonl` structured face (phase 3; process visibility
/// extension 2026-09-08).
///
/// With `--jsonl`, stdout carries a pure event stream: one JSON object per
/// line, no separate human summary and no separate marker line (both fold
/// into the terminal events). Wire schema, v1.1 (additive over the frozen
/// v1 — new event types and new trailing fields only, so consumers keyed on
/// `type` and known fields keep working):
///
///   {"type":"turn_started","turn":1,"session":"<session_id>"}
///   {"type":"reasoning","turn":1,"content":"...","truncated":false}
///   {"type":"tool_call","turn":1,"name":"<tool_name>","call_id":"<id>","arguments":{...}}
///   {"type":"tool_result","turn":1,"name":"<tool_name>","call_id":"<id>","is_error":false,"outcome":"success","content":"...","truncated":false}
///   {"type":"turn_completed","turn":1,"summary":"...","marker":"[cetas-headless] turn 1 done","usage":{"turns":1,"input_tokens":0,"output_tokens":0}}
///   {"type":"turn_failed","turn":1,"error":"...","marker":"[cetas-headless] turn 1 done"}
///
/// With `--jsonl --stream` two delta event types ride along as live
/// telemetry (`{"type":"reasoning_delta","turn":1,"token":"..."}` and the
/// text twin); the committed `reasoning` / `turn_completed` events stay
/// authoritative — deltas may be dropped under load (StreamChunksDropped),
/// committed events never are.
///
/// Event projection: ToolCallPending / ToolCallResult / committed reasoning
/// from ModelResponseReceived; usage accumulates from ModelResponseReceived
/// exactly like ext-subagent's BridgeObserver. `content` fields are preview
/// clips (`preview_cap` chars) — the full transcript (reasoning, arguments,
/// complete tool results) is persisted in the fs-session JSONL store; stdout
/// is a notification channel, not the record.
///
/// Every line is delivered the moment it is built: `set_live_sink` (wired by
/// the loop's pump) receives it synchronously; without a sink lines buffer
/// for `take_lines`. Line order is identical either way.

///|
/// Quote and escape one string as a JSON scalar. Event lines are assembled
/// by explicit concatenation so the frozen key order stays byte-stable
/// (interpolation cannot carry the `\"key\":` fragments — inside `\{...}`
/// the lexer is in expression mode).
fn json_scalar(s : String) -> String {
  Json::string(s).stringify()
}

///|
/// Preview clip cap for `content` fields on the wire. Deliberately small:
/// headless output is a rollup for drivers and one-shot bash usage, not the
/// record (that lives in the session store).
const PREVIEW_CAP : Int = 1024

///|
/// Clip `text` to at most `PREVIEW_CAP` characters. Returns the clip and
/// whether anything was cut. Char-wise (not code-unit-wise) so multi-byte
/// text never splits a surrogate pair.
fn clip_preview(text : String) -> (String, Bool) {
  let builder = StringBuilder()
  let mut count = 0
  let mut truncated = false
  for ch in text {
    if count >= PREVIEW_CAP {
      truncated = true
      break
    }
    builder.write_char(ch)
    count += 1
  }
  (builder.to_string(), truncated)
}

///|
/// The `outcome` wire tag for one ToolOutcome variant.
fn outcome_tag(outcome : @posoco.ToolOutcome) -> String {
  match outcome {
    Success(..) => "success"
    ToolReportedError(..) => "tool_error"
    RuntimeFailure(..) => "runtime_failure"
    NotExecuted(..) => "not_executed"
  }
}

///|
/// The human-meaningful payload of one ToolOutcome: the result content, or
/// the failure message, or the not-executed reason.
fn outcome_text(outcome : @posoco.ToolOutcome) -> String {
  match outcome {
    Success(content~, ..) => content
    ToolReportedError(content~, ..) => content
    RuntimeFailure(error_category~, message~) => "\{error_category}: \{message}"
    NotExecuted(reason~, ..) => reason.to_string()
  }
}

///|
pub struct JsonlObserver {
  /// Current headless turn number, set by the loop before each run.
  mut turn : Int
  /// Session attribution for turn_started lines, set with the turn number.
  mut session_id : String
  /// Per-turn usage window (reset at begin_turn), BridgeObserver pattern.
  mut turns_completed : Int
  mut input_tokens : Int
  mut output_tokens : Int
  /// Buffered event lines (no trailing newline); drained by the loop. Empty
  /// in live mode — the sink receives each line as it is built.
  mut lines : Array[String]
  /// `--stream`: also project ReasoningDelta / TextDelta as telemetry
  /// events. Committed events are emitted regardless.
  stream : Bool
  /// Live sink: when attached, every completed line is delivered here the
  /// moment it is built; otherwise it buffers above.
  mut sink : ((String) -> Unit)?
}

///|
pub fn JsonlObserver::JsonlObserver(stream? : Bool = false) -> JsonlObserver {
  {
    turn: 0,
    session_id: "",
    turns_completed: 0,
    input_tokens: 0,
    output_tokens: 0,
    lines: [],
    stream,
    sink: None,
  }
}

///|
/// Attach the live sink (the loop's queue). After this, built lines go to
/// the sink instead of the buffer.
pub fn JsonlObserver::set_live_sink(
  self : JsonlObserver,
  sink : (String) -> Unit,
) -> Unit {
  self.sink = Some(sink)
}

///|
/// The loop announces each turn before running it: this pins the turn number
/// and session attribution for every event the kernel emits during the run
/// and opens a fresh usage window.
pub fn JsonlObserver::begin_turn(
  self : JsonlObserver,
  turn_no~ : Int,
  session_id~ : String,
) -> Unit {
  self.turn = turn_no
  self.session_id = session_id
  self.turns_completed = 0
  self.input_tokens = 0
  self.output_tokens = 0
}

///|
/// Take the buffered event lines in order; the buffer is left empty. Only
/// meaningful without a live sink (buffered mode / tests).
pub fn JsonlObserver::take_lines(self : JsonlObserver) -> Array[String] {
  let out = self.lines
  self.lines = []
  out
}

///|
/// Deliver one built line: to the live sink when attached, else to the
/// buffer.
fn JsonlObserver::push_line(self : JsonlObserver, line : String) -> Unit {
  match self.sink {
    Some(sink) => sink(line)
    None => self.lines.push(line)
  }
}

///|
fn JsonlObserver::usage_json(self : JsonlObserver) -> String {
  "{\"turns\":" +
  self.turns_completed.to_string() +
  ",\"input_tokens\":" +
  self.input_tokens.to_string() +
  ",\"output_tokens\":" +
  self.output_tokens.to_string() +
  "}"
}

///|
/// Loop-side terminal event for a completed turn: the summary text and the
/// fixed marker fold into one line so `wait output --match` works on it.
pub fn JsonlObserver::emit_turn_completed(
  self : JsonlObserver,
  summary~ : String,
  marker~ : String,
) -> Unit {
  self.push_line(
    "{\"type\":\"turn_completed\",\"turn\":" +
    self.turn.to_string() +
    ",\"summary\":" +
    json_scalar(summary) +
    ",\"marker\":" +
    json_scalar(marker) +
    ",\"usage\":" +
    self.usage_json() +
    "}",
  )
}

///|
/// Loop-side terminal event for a failed turn; the marker rides along so
/// waiting drivers never deadlock on a failure.
pub fn JsonlObserver::emit_turn_failed(
  self : JsonlObserver,
  error~ : String,
  marker~ : String,
) -> Unit {
  self.push_line(
    "{\"type\":\"turn_failed\",\"turn\":" +
    self.turn.to_string() +
    ",\"error\":" +
    json_scalar(error) +
    ",\"marker\":" +
    json_scalar(marker) +
    "}",
  )
}

///|
pub impl @posoco.Observer for JsonlObserver with fn on_event_at(
  self,
  _scope : @posoco.EventScope?,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::TurnStarted =>
      self.push_line(
        "{\"type\":\"turn_started\",\"turn\":" +
        self.turn.to_string() +
        ",\"session\":" +
        json_scalar(self.session_id) +
        "}",
      )
    @posoco.TurnEvent::ToolCallPending(call) =>
      self.push_line(
        "{\"type\":\"tool_call\",\"turn\":" +
        self.turn.to_string() +
        ",\"name\":" +
        json_scalar(call.name.to_string()) +
        ",\"call_id\":" +
        json_scalar(call.call_id.to_string()) +
        ",\"arguments\":" +
        call.arguments.stringify() +
        "}",
      )
    @posoco.TurnEvent::ToolCallResult(call~, result~, is_error~) => {
      let (content, truncated) = clip_preview(outcome_text(result))
      self.push_line(
        "{\"type\":\"tool_result\",\"turn\":" +
        self.turn.to_string() +
        ",\"name\":" +
        json_scalar(call.name.to_string()) +
        ",\"call_id\":" +
        json_scalar(call.call_id.to_string()) +
        ",\"is_error\":" +
        is_error.to_string() +
        ",\"outcome\":" +
        json_scalar(outcome_tag(result)) +
        ",\"content\":" +
        json_scalar(content) +
        ",\"truncated\":" +
        truncated.to_string() +
        "}",
      )
    }
    @posoco.TurnEvent::ModelResponseReceived(message~, usage~) => {
      match message {
        AssistantMessage(reasoning~, ..) =>
          match reasoning {
            Some(trace) => {
              let (content, truncated) = clip_preview(trace.content)
              self.push_line(
                "{\"type\":\"reasoning\",\"turn\":" +
                self.turn.to_string() +
                ",\"content\":" +
                json_scalar(content) +
                ",\"truncated\":" +
                truncated.to_string() +
                "}",
              )
            }
            None => ()
          }
        _ => ()
      }
      match usage {
        Some(u) => {
          match u.input_tokens {
            Some(n) => self.input_tokens = self.input_tokens + n
            None => ()
          }
          match u.output_tokens {
            Some(n) => self.output_tokens = self.output_tokens + n
            None => ()
          }
        }
        None => ()
      }
    }
    @posoco.TurnEvent::StreamChunkReceived(chunk~) =>
      if self.stream {
        match chunk {
          ReasoningDelta(token~) =>
            self.push_line(
              "{\"type\":\"reasoning_delta\",\"turn\":" +
              self.turn.to_string() +
              ",\"token\":" +
              json_scalar(token) +
              "}",
            )
          TextDelta(token~) =>
            self.push_line(
              "{\"type\":\"text_delta\",\"turn\":" +
              self.turn.to_string() +
              ",\"token\":" +
              json_scalar(token) +
              "}",
            )
          _ => ()
        }
      }
    @posoco.TurnEvent::TurnCompleted =>
      self.turns_completed = self.turns_completed + 1
    _ => ()
  }
}

///|
/// Self-report the observer as an extension so it can ride `tail_exts` into
/// the composition (ACP bridge registration precedent).
pub impl @posoco.Extension for JsonlObserver with fn extension_id(_self) -> String {
  "cetas_headless_jsonl"
}

///|
pub impl @posoco.Extension for JsonlObserver with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "cetas_headless_jsonl",
    models: [],
    tools: [],
    sessions: [],
    observers: [self],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [],
    requires: [],
  }
}
