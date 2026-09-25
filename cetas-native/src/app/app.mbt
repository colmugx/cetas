/// Native terminal-shell state reducer.
///
/// This is the MoonBit replacement seam for the current cetas-js
/// EventRouter + streaming controllers. It owns semantic event routing only:
/// no terminal IO and no Ratatui values cross this package.

///|
pub(all) enum ShellStatus {
  ShellIdle
  ShellWorking(String)
  ShellFailed(String)
} derive(Eq)

///|
pub extend ShellStatus with Eq::{equal, not_equal}

///|
pub struct NativeShell {
  transcript : @ui.TranscriptModel
  tools : @ui.ToolStreamingModel
  mut pending_tool_rows : Map[Int, Int]
  mut tool_rows : Map[String, Int]
  queued_prompt_rows : Array[Int]
  mut interrupt_requested : Bool
  mut status : ShellStatus
}

///|
pub fn NativeShell::new() -> NativeShell {
  {
    transcript: @ui.TranscriptModel::new(),
    tools: @ui.ToolStreamingModel::new(),
    pending_tool_rows: Map::from_array([]),
    tool_rows: Map::from_array([]),
    queued_prompt_rows: [],
    interrupt_requested: false,
    status: ShellIdle,
  }
}

///|
pub fn NativeShell::status(self : NativeShell) -> ShellStatus {
  self.status
}

///|
pub fn NativeShell::transcript(self : NativeShell) -> @ui.TranscriptModel {
  self.transcript
}

///|
pub fn NativeShell::begin_turn(self : NativeShell) -> Unit {
  self.interrupt_requested = false
  self.tools.end_turn()
  self.pending_tool_rows = Map::from_array([])
  self.tool_rows = Map::from_array([])
  self.promote_queued_prompt()
  self.transcript.begin_turn()
  self.status = ShellWorking("thinking")
}

///|
/// Record an already-accepted follow-up from the application's bounded queue.
///
/// Queue capacity/stale-race policy belongs to the application boundary. This
/// reducer owns only the visible semantic bubble after queueFollowUp accepts it.
pub fn NativeShell::queue_follow_up(
  self : NativeShell,
  prompt : String,
) -> Int {
  let row_id = self.transcript.append_queued_user(prompt)
  self.queued_prompt_rows.push(row_id)
  row_id
}

///|
pub fn NativeShell::queued_prompt_count(self : NativeShell) -> Int {
  self.queued_prompt_rows.length()
}

///|
fn NativeShell::promote_queued_prompt(self : NativeShell) -> Unit {
  if self.queued_prompt_rows.is_empty() {
    return
  }
  let row_id = self.queued_prompt_rows.remove(0)
  ignore(self.transcript.promote_queued_user(row_id))
}

///|
fn NativeShell::promote_all_queued_prompts(self : NativeShell) -> Unit {
  while !self.queued_prompt_rows.is_empty() {
    self.promote_queued_prompt()
  }
}

///|
/// Mark that the user requested cancellation of the active operation.
///
/// The side effect that actually aborts the Agent belongs to the host. This
/// flag only disambiguates the later safe-category TurnFailed event so the UI
/// can render interruption once instead of showing it as an error.
pub fn NativeShell::request_interrupt(self : NativeShell) -> Unit {
  self.interrupt_requested = true
}

///|
pub fn NativeShell::interrupt_requested(self : NativeShell) -> Bool {
  self.interrupt_requested
}

///|
fn NativeShell::finish_interrupted_turn(self : NativeShell) -> Unit {
  self.freeze_pending_tools()
  self.tools.end_turn()
  self.transcript.end_turn()
  self.tool_rows = Map::from_array([])
  self.promote_all_queued_prompts()
  ignore(self.transcript.append_finalized(
    @ui.TranscriptSystem,
    "⏹ interrupted",
  ))
  self.interrupt_requested = false
  self.status = ShellIdle
}

///|
pub fn NativeShell::append_reasoning(
  self : NativeShell,
  token : String,
) -> Unit {
  self.transcript.append_reasoning(token)
  self.status = ShellWorking("thinking")
}

///|
pub fn NativeShell::append_text(
  self : NativeShell,
  token : String,
) -> Unit {
  self.transcript.append_text(token)
  self.status = ShellWorking("responding")
}

///|
pub fn NativeShell::message_end(
  self : NativeShell,
  reasoning : String,
  text : String,
) -> Unit {
  self.transcript.message_end(reasoning, text)
}

///|
fn tool_live_text(
  name : String?,
  args : String,
) -> String {
  let label = match name {
    Some(value) if !value.is_empty() => value
    _ => "tool"
  }
  if args.is_empty() {
    "● " + label
  } else {
    "● " + label + " " + args
  }
}

///|
/// Feed one lossy tool-args delta. The stable pending slot keeps all fragments
/// mounted on one semantic transcript row even before the wire id is known.
pub fn NativeShell::tool_args_delta(
  self : NativeShell,
  index : Int,
  id : String?,
  name : String?,
  delta : String?,
) -> Unit {
  let pending = self.tools.on_args_delta(index, id, name, delta)
  let text = tool_live_text(pending.name, pending.raw_args)

  match self.pending_tool_rows.get(pending.slot) {
    Some(row_id) => ignore(self.transcript.update_row(row_id, text))
    None => {
      let row_id = self.transcript.append_live(@ui.TranscriptTool, text)
      self.pending_tool_rows[pending.slot] = row_id
    }
  }
}

///|
/// Adopt a streamed row when possible; otherwise create the classic
/// non-streaming row. Authoritative args replace the lossy partial buffer.
pub fn NativeShell::tool_call_started(
  self : NativeShell,
  tool_call_id : String,
  tool_name : String,
  authoritative_args : String,
) -> Unit {
  let adopted = self.tools.on_call_started(
    tool_call_id,
    tool_name,
    authoritative_args,
  )

  let row_id = match adopted {
    Some(pending) =>
      match self.pending_tool_rows.get(pending.slot) {
        Some(existing) => {
          ignore(self.pending_tool_rows.remove(pending.slot))
          ignore(self.transcript.update_row(
            existing,
            tool_live_text(Some(tool_name), authoritative_args),
          ))
          existing
        }
        None =>
          self.transcript.append_live(
            @ui.TranscriptTool,
            tool_live_text(Some(tool_name), authoritative_args),
          )
      }
    None =>
      self.transcript.append_live(
        @ui.TranscriptTool,
        tool_live_text(Some(tool_name), authoritative_args),
      )
  }

  self.tool_rows[tool_call_id] = row_id
  self.status = ShellWorking("running " + tool_name)
}

///|
pub fn NativeShell::tool_call_completed(
  self : NativeShell,
  tool_call_id : String,
  result : String,
  is_error : Bool,
) -> Unit {
  match self.tool_rows.get(tool_call_id) {
    Some(row_id) => {
      let prefix = if is_error { "✗ " } else { "✓ " }
      ignore(self.transcript.update_row(row_id, prefix + result))
      ignore(self.transcript.finalize(row_id))
    }
    None => ()
  }

  if self.transcript.is_in_turn() {
    self.status = ShellWorking("waiting for model")
  }
}

///|
fn NativeShell::freeze_pending_tools(self : NativeShell) -> Unit {
  for _, row_id in self.pending_tool_rows {
    ignore(self.transcript.finalize(row_id))
  }
  self.pending_tool_rows = Map::from_array([])
}

///|
pub fn NativeShell::end_turn(self : NativeShell) -> Unit {
  self.interrupt_requested = false
  self.freeze_pending_tools()
  self.tools.end_turn()
  self.transcript.end_turn()
  self.tool_rows = Map::from_array([])
  self.status = ShellIdle
}

///|
pub fn NativeShell::fail_turn(
  self : NativeShell,
  message : String,
) -> Unit {
  if self.interrupt_requested {
    self.finish_interrupted_turn()
    return
  }
  self.interrupt_requested = false
  self.freeze_pending_tools()
  self.tools.end_turn()
  self.transcript.end_turn()
  self.tool_rows = Map::from_array([])
  self.promote_all_queued_prompts()
  ignore(self.transcript.append_finalized(@ui.TranscriptError, message))
  self.status = ShellFailed(message)
}

///|
pub fn NativeShell::take_scrollback_ready(
  self : NativeShell,
) -> Array[@ui.TranscriptRowSnapshot] {
  self.transcript.take_scrollback_ready()
}

///|
pub fn NativeShell::append_live_scene(
  self : NativeShell,
  builder : @ui.SceneBuilder,
  x : UInt,
  y : UInt,
  width : UInt,
) -> UInt {
  self.transcript.append_live_scene(builder, x, y, width)
}

///|
pub fn validation_marker() -> Int {
  let shell = NativeShell::new()
  shell.begin_turn()
  shell.append_reasoning("think")
  shell.append_text("answer")
  shell.message_end("think", "answer")

  // Index-only fragment becomes id-bearing without creating a second row.
  shell.tool_args_delta(0, None, Some("write"), Some("{\"path\":"))
  shell.tool_args_delta(0, Some("call-1"), None, Some("\"a\""))
  shell.tool_call_started(
    "call-1",
    "write",
    "{\"path\":\"a\",\"content\":\"full\"}",
  )
  shell.tool_call_completed("call-1", "wrote a", false)
  shell.end_turn()

  if shell.status() != ShellIdle ||
    shell.transcript().row_count() != 3 ||
    shell.transcript().row(2).kind != @ui.TranscriptTool ||
    shell.transcript().row(2).text != "✓ wrote a" ||
    !shell.transcript().row(2).finalized {
    return 0
  }

  let ready = shell.take_scrollback_ready()
  if ready.length() != 3 || !shell.take_scrollback_ready().is_empty() {
    return 0
  }

  // A started-less streamed tool freezes at its last partial view on end_turn.
  shell.begin_turn()
  shell.tool_args_delta(1, None, Some("grep"), Some("{\"q\":\"foo"))
  shell.end_turn()
  if shell.transcript().row_count() != 4 ||
    !shell.transcript().row(3).finalized {
    return 0
  }

  // Accepted follow-ups stay live/queued until subsequent TurnStarted events
  // promote them oldest-first. A failed outer operation promotes leftovers so
  // no bubble can remain permanently marked queued.
  let queue_shell = NativeShell::new()
  queue_shell.begin_turn()
  let first_queued = queue_shell.queue_follow_up("first follow-up")
  let second_queued = queue_shell.queue_follow_up("second follow-up")
  if queue_shell.queued_prompt_count() != 2 ||
    queue_shell.transcript().row(0).kind != @ui.TranscriptQueuedUser ||
    queue_shell.transcript().take_scrollback_ready().length() != 0 {
    return 0
  }
  queue_shell.end_turn()
  queue_shell.begin_turn()
  if queue_shell.queued_prompt_count() != 1 ||
    queue_shell.transcript().row(0).id != first_queued ||
    queue_shell.transcript().row(0).kind != @ui.TranscriptUser ||
    !queue_shell.transcript().row(0).finalized ||
    queue_shell.transcript().row(1).id != second_queued ||
    queue_shell.transcript().row(1).kind != @ui.TranscriptQueuedUser {
    return 0
  }
  queue_shell.fail_turn("stop")
  if queue_shell.queued_prompt_count() != 0 ||
    queue_shell.transcript().row(1).kind != @ui.TranscriptUser ||
    !queue_shell.transcript().row(1).finalized {
    return 0
  }

  let interrupted = NativeShell::new()
  interrupted.begin_turn()
  ignore(interrupted.queue_follow_up("will not drain"))
  interrupted.request_interrupt()
  if !interrupted.interrupt_requested() {
    return 0
  }
  interrupted.fail_turn("cancelled")
  if interrupted.status() != ShellIdle ||
    interrupted.interrupt_requested() ||
    interrupted.queued_prompt_count() != 0 ||
    interrupted.transcript().row_count() != 2 ||
    interrupted.transcript().row(0).kind != @ui.TranscriptUser ||
    interrupted.transcript().row(1).kind != @ui.TranscriptSystem ||
    interrupted.transcript().row(1).text != "⏹ interrupted" {
    return 0
  }

  if event_wire_validation_marker() != 1 {
    return 0
  }
  if typed_observer_validation_marker() != 1 {
    return 0
  }
  if input_validation_marker() != 1 {
    return 0
  }
  snapshot_validation_marker()
}
