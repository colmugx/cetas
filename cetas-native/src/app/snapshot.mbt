/// Stable semantic snapshot used by cross-host parity fixtures.

///|
fn transcript_kind_name(kind : @ui.TranscriptRowKind) -> String {
  match kind {
    @ui.TranscriptUser => "user"
    @ui.TranscriptQueuedUser => "queued_user"
    @ui.TranscriptThinking => "thinking"
    @ui.TranscriptAssistant => "assistant"
    @ui.TranscriptTool => "tool"
    @ui.TranscriptSystem => "system"
    @ui.TranscriptError => "error"
  }
}

///|
fn shell_status_json(status : ShellStatus) -> Json {
  match status {
    ShellIdle =>
      Json::object(Map::from_array([
        ("kind", Json::string("idle")),
      ]))
    ShellWorking(message) =>
      Json::object(Map::from_array([
        ("kind", Json::string("working")),
        ("message", Json::string(message)),
      ]))
    ShellFailed(message) =>
      Json::object(Map::from_array([
        ("kind", Json::string("failed")),
        ("message", Json::string(message)),
      ]))
  }
}

///|
/// Normalize state into a deterministic JSON shape shared by parity harnesses.
pub fn NativeShell::snapshot_json(self : NativeShell) -> Json {
  let rows : Array[Json] = []
  let transcript = self.transcript()
  for i = 0; i < transcript.row_count(); i = i + 1 {
    let row = transcript.row(i)
    rows.push(
      Json::object(Map::from_array([
        ("id", Json::number(row.id.to_double())),
        ("kind", Json::string(transcript_kind_name(row.kind))),
        ("text", Json::string(row.text)),
        (
          "finalized",
          Json::boolean(row.finalized),
        ),
      ])),
    )
  }

  Json::object(Map::from_array([
    ("status", shell_status_json(self.status())),
    ("rows", Json::array(rows)),
  ]))
}

///|
pub fn snapshot_validation_marker() -> Int {
  let shell = NativeShell::new()
  shell.begin_turn()
  shell.append_text("hello")
  shell.end_turn()
  guard shell.snapshot_json() is Json::Object(fields) else {
    return 0
  }
  guard fields.get("rows") is Some(Json::Array(rows)) else {
    return 0
  }
  guard rows.length() == 1 && rows[0] is Json::Object(row) else {
    return 0
  }
  guard row.get("kind") == Some(Json::string("assistant")) &&
    row.get("text") == Some(Json::string("hello")) &&
    row.get("finalized") == Some(Json::boolean(true)) else {
    return 0
  }
  guard fields.get("status") is Some(Json::Object(status)) else {
    return 0
  }
  if status.get("kind") == Some(Json::string("idle")) { 1 } else { 0 }
}
