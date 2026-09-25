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
          if row.finalized { Json::True } else { Json::False },
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
  let expected = "{\"rows\":[{\"finalized\":true,\"id\":1,\"kind\":\"assistant\",\"text\":\"hello\"}],\"status\":{\"kind\":\"idle\"}}"
  if shell.snapshot_json().stringify() == expected {
    1
  } else {
    0
  }
}
