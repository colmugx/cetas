///|
/// jsonl.mbt — the `--jsonl` structured face (phase 3).
///
/// With `--jsonl`, stdout carries a pure event stream: one JSON object per
/// line, no separate human summary and no separate marker line (both fold
/// into the terminal events). Frozen wire schema — Wave 5 parses it:
///
///   {"type":"turn_started","turn":1,"session":"<session_id>"}
///   {"type":"tool_result","turn":1,"name":"<tool_name>","call_id":"<id>","is_error":false}
///   {"type":"turn_completed","turn":1,"summary":"...","marker":"[cetas-headless] turn 1 done","usage":{"turns":1,"input_tokens":0,"output_tokens":0}}
///   {"type":"turn_failed","turn":1,"error":"...","marker":"[cetas-headless] turn 1 done"}
///
/// The observer rides the composition as an extension (ACP bridge
/// precedent) and projects TurnStarted / ToolCallResult as the kernel emits
/// them; per-turn usage accumulates from ModelResponseReceived exactly like
/// ext-subagent's BridgeObserver. The loop owns turn numbering (begin_turn)
/// and the terminal state, so turn_completed / turn_failed are emitted by
/// the loop carrying the marker string.
///
/// Observer callbacks are synchronous, so lines buffer here and the loop
/// drains them to stdout after the turn — the emitted line sequence is
/// identical to streaming because nothing else writes stdout mid-turn.

///|
/// Quote and escape one string as a JSON scalar. Event lines are assembled
/// by explicit concatenation so the frozen key order stays byte-stable
/// (interpolation cannot carry the `\"key\":` fragments — inside `\{...}`
/// the lexer is in expression mode).
fn json_scalar(s : String) -> String {
  Json::string(s).stringify()
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
  /// Buffered event lines (no trailing newline); drained by the loop.
  mut lines : Array[String]
}

///|
pub fn JsonlObserver::JsonlObserver() -> JsonlObserver {
  {
    turn: 0,
    session_id: "",
    turns_completed: 0,
    input_tokens: 0,
    output_tokens: 0,
    lines: [],
  }
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
/// Take the buffered event lines in order; the buffer is left empty.
pub fn JsonlObserver::take_lines(self : JsonlObserver) -> Array[String] {
  let out = self.lines
  self.lines = []
  out
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
  self.lines.push(
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
  self.lines.push(
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
impl @posoco.Observer for JsonlObserver with fn on_event_at(
  self,
  _scope : @posoco.EventScope?,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::TurnStarted =>
      self.lines.push(
        "{\"type\":\"turn_started\",\"turn\":" +
        self.turn.to_string() +
        ",\"session\":" +
        json_scalar(self.session_id) +
        "}",
      )
    @posoco.TurnEvent::ToolCallResult(call~, is_error~, ..) =>
      self.lines.push(
        "{\"type\":\"tool_result\",\"turn\":" +
        self.turn.to_string() +
        ",\"name\":" +
        json_scalar(call.name.to_string()) +
        ",\"call_id\":" +
        json_scalar(call.call_id.to_string()) +
        ",\"is_error\":" +
        is_error.to_string() +
        "}",
      )
    @posoco.TurnEvent::ModelResponseReceived(usage~, ..) =>
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
