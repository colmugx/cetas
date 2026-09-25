/// MoonBit-owned transcript and streaming assistant reducer.
///
/// The model is semantic: it knows about transcript row lifecycle, but not
/// terminal cells or Ratatui widgets. Immutable finalized rows may later be
/// committed to terminal scrollback; live rows remain in the inline scene.

///|
pub(all) enum TranscriptRowKind {
  TranscriptUser
  TranscriptQueuedUser
  TranscriptThinking
  TranscriptAssistant
  TranscriptTool
  TranscriptSystem
  TranscriptError
} derive(Eq)

///|
pub extend TranscriptRowKind with Eq::{equal, not_equal}

///|
pub(all) struct TranscriptRow {
  id : Int
  kind : TranscriptRowKind
  mut text : String
  mut finalized : Bool
  mut scrollback_committed : Bool
}

///|
pub(all) struct TranscriptRowSnapshot {
  id : Int
  kind : TranscriptRowKind
  text : String
}

///|
pub struct TranscriptModel {
  rows : Array[TranscriptRow]
  mut next_id : Int
  mut in_turn : Bool
  mut streamed_this_turn : Bool
  mut thinking_id : Int?
  mut text_id : Int?
}

///|
pub fn TranscriptModel::new() -> TranscriptModel {
  {
    rows: [],
    next_id: 1,
    in_turn: false,
    streamed_this_turn: false,
    thinking_id: None,
    text_id: None,
  }
}

///|
pub fn TranscriptModel::row_count(self : TranscriptModel) -> Int {
  self.rows.length()
}

///|
pub fn TranscriptModel::row(self : TranscriptModel, index : Int) -> TranscriptRow {
  self.rows[index]
}

///|
fn TranscriptModel::append_row(
  self : TranscriptModel,
  kind : TranscriptRowKind,
  text : String,
  finalized~ : Bool,
) -> Int {
  let id = self.next_id
  self.next_id += 1
  self.rows.push({
    id,
    kind,
    text,
    finalized,
    scrollback_committed: false,
  })
  id
}

///|
fn TranscriptModel::find_row_index(
  self : TranscriptModel,
  id : Int,
) -> Int? {
  for index, row in self.rows {
    if row.id == id {
      return Some(index)
    }
  }
  None
}

///|
fn TranscriptModel::append_row_text(
  self : TranscriptModel,
  id : Int,
  delta : String,
) -> Unit {
  match self.find_row_index(id) {
    Some(index) => self.rows[index].text += delta
    None => ()
  }
}

///|
fn TranscriptModel::finalize_row(
  self : TranscriptModel,
  id : Int,
) -> Unit {
  match self.find_row_index(id) {
    Some(index) => self.rows[index].finalized = true
    None => ()
  }
}

///|
pub fn TranscriptModel::begin_turn(self : TranscriptModel) -> Unit {
  // A previous turn must already be closed by the shell reducer. Be defensive
  // here so a duplicate turn_started can never mutate frozen rows.
  self.close_step()
  self.in_turn = true
  self.streamed_this_turn = false
}

///|
pub fn TranscriptModel::is_in_turn(self : TranscriptModel) -> Bool {
  self.in_turn
}

///|
pub fn TranscriptModel::has_streamed_this_turn(
  self : TranscriptModel,
) -> Bool {
  self.streamed_this_turn
}

///|
/// Finalize the current step and drop its live references.
///
/// Mounted/finalized transcript rows remain in the append-only history.
pub fn TranscriptModel::close_step(self : TranscriptModel) -> Unit {
  match self.thinking_id {
    Some(id) => self.finalize_row(id)
    None => ()
  }
  match self.text_id {
    Some(id) => self.finalize_row(id)
    None => ()
  }
  self.thinking_id = None
  self.text_id = None
}

///|
/// Reasoning follows the provider ordering contract used by cetas-js:
/// reasoning may precede text, but text -> reasoning means a new model step.
pub fn TranscriptModel::append_reasoning(
  self : TranscriptModel,
  token : String,
) -> Unit {
  self.streamed_this_turn = true

  match self.text_id {
    Some(_) => self.close_step()
    None => ()
  }

  let id = match self.thinking_id {
    Some(value) => value
    None => {
      let value = self.append_row(
        TranscriptThinking,
        "",
        finalized=false,
      )
      self.thinking_id = Some(value)
      value
    }
  }
  self.append_row_text(id, token)
}

///|
/// The first text token finalizes live reasoning in the same step.
pub fn TranscriptModel::append_text(
  self : TranscriptModel,
  token : String,
) -> Unit {
  self.streamed_this_turn = true

  match self.thinking_id {
    Some(id) => self.finalize_row(id)
    None => ()
  }

  let id = match self.text_id {
    Some(value) => value
    None => {
      let value = self.append_row(
        TranscriptAssistant,
        "",
        finalized=false,
      )
      self.text_id = Some(value)
      value
    }
  }
  self.append_row_text(id, token)
}

///|
/// Reconcile one post-hoc message_end.
///
/// Once any stream chunk has appeared in the turn, message_end only closes
/// the current step. This is the duplicate-suppression rule from
/// cetas-js StreamingUIController/EventRouter.
///
/// A non-streaming provider instead materializes finalized reasoning/text rows.
pub fn TranscriptModel::message_end(
  self : TranscriptModel,
  reasoning : String,
  text : String,
) -> Unit {
  if self.streamed_this_turn {
    self.close_step()
    return
  }

  if !reasoning.trim().is_empty() {
    ignore(self.append_row(
      TranscriptThinking,
      reasoning.trim().to_owned(),
      finalized=true,
    ))
  }
  if !text.is_empty() {
    ignore(self.append_row(
      TranscriptAssistant,
      text,
      finalized=true,
    ))
  }
  self.close_step()
}

///|
pub fn TranscriptModel::end_turn(self : TranscriptModel) -> Unit {
  self.close_step()
  self.in_turn = false
  self.streamed_this_turn = false
}

///|
/// Append an already-finalized semantic row such as a user echo or notice.
pub fn TranscriptModel::append_finalized(
  self : TranscriptModel,
  kind : TranscriptRowKind,
  text : String,
) -> Int {
  self.append_row(kind, text, finalized=true)
}

///|
/// Return every finalized row that has not yet crossed the scrollback
/// boundary, in transcript order, and atomically mark it committed.
///
/// Callers should lower these snapshots to immutable text/scene output and use
/// Terminal::insert_before. Live rows are never returned.
pub fn TranscriptModel::take_scrollback_ready(
  self : TranscriptModel,
) -> Array[TranscriptRowSnapshot] {
  let ready : Array[TranscriptRowSnapshot] = []
  for index, row in self.rows {
    if row.finalized && !row.scrollback_committed {
      ready.push({
        id: row.id,
        kind: row.kind,
        text: row.text,
      })
      self.rows[index].scrollback_committed = true
    }
  }
  ready
}

///|
/// Deterministic plain-text lowering for immutable terminal scrollback.
///
/// Rich Markdown/tool renderers can replace this representation later without
/// changing transcript identity or scrollback ownership.
pub fn TranscriptRowSnapshot::scrollback_text(
  self : TranscriptRowSnapshot,
) -> String {
  match self.kind {
    TranscriptUser => "> " + self.text
    TranscriptQueuedUser => "> " + self.text + " · queued"
    TranscriptThinking => "💭 thought\n" + self.text
    TranscriptAssistant => self.text
    TranscriptTool => "● " + self.text
    TranscriptSystem => "· " + self.text
    TranscriptError => "● error: " + self.text
  }
}

///|
/// Lower only mutable/live transcript rows into the inline scene.
///
/// Finalized rows are intentionally omitted: after finalization they belong to
/// the scrollback handoff path and must never be painted in both regions.
pub fn TranscriptModel::append_live_scene(
  self : TranscriptModel,
  builder : SceneBuilder,
  x : UInt,
  y : UInt,
  width : UInt,
) -> UInt {
  let mut row_y = y
  for row in self.rows {
    if !row.finalized {
      let prefix = match row.kind {
        TranscriptThinking => "💭 "
        TranscriptAssistant => ""
        TranscriptTool => "● "
        TranscriptUser => "> "
        TranscriptQueuedUser => "> "
        TranscriptSystem => "· "
        TranscriptError => "● "
      }
      let bytes = @utf8.encode(prefix + row.text)
      builder.text(
        x,
        row_y,
        width,
        1U,
        bytes,
      )
      row_y += 1U
    }
  }
  row_y
}

///|
pub fn transcript_validation_marker() -> Int {
  // reasoning -> text stays in one step and both rows finalize on close.
  let transcript = TranscriptModel::new()
  transcript.begin_turn()
  transcript.append_reasoning("think")
  transcript.append_text("hello")
  transcript.message_end("think", "hello")
  if transcript.row_count() != 2 ||
    transcript.row(0).kind != TranscriptThinking ||
    transcript.row(0).text != "think" ||
    !transcript.row(0).finalized ||
    transcript.row(1).kind != TranscriptAssistant ||
    transcript.row(1).text != "hello" ||
    !transcript.row(1).finalized {
    return 0
  }

  // The post-hoc replay must not duplicate streamed content.
  transcript.message_end("think", "hello")
  if transcript.row_count() != 2 {
    return 0
  }

  // text -> reasoning opens a new model step.
  transcript.append_text("first")
  transcript.append_reasoning("second thought")
  transcript.append_text("second answer")
  transcript.end_turn()
  if transcript.row_count() != 5 ||
    transcript.row(2).text != "first" ||
    transcript.row(3).kind != TranscriptThinking ||
    transcript.row(4).kind != TranscriptAssistant {
    return 0
  }

  // Scrollback handoff is one-shot.
  let first_commit = transcript.take_scrollback_ready()
  if first_commit.length() != 5 ||
    first_commit[0].scrollback_text() != "💭 thought\nthink" ||
    !transcript.take_scrollback_ready().is_empty() {
    return 0
  }

  let live = TranscriptModel::new()
  live.begin_turn()
  live.append_reasoning("streaming")
  let builder = SceneBuilder::new()
  let next_y = live.append_live_scene(builder, 0U, 2U, 40U)
  let live_scene = builder.finish()
  if next_y != 3U ||
    live_scene.words.length() != 8 ||
    live_scene.text != b"💭 streaming" {
    return 0
  }

  // Non-streaming message_end constructs finalized rows directly.
  let non_streaming = TranscriptModel::new()
  non_streaming.begin_turn()
  non_streaming.message_end(" reason ", "answer")
  non_streaming.end_turn()
  if non_streaming.row_count() != 2 ||
    non_streaming.row(0).text != "reason" ||
    non_streaming.row(1).text != "answer" {
    return 0
  }

  1
}
