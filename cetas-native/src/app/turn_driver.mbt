/// Background Agent-turn driver for the native terminal host.
///
/// The terminal loop stays responsive while an Agent turn runs in a child
/// task. This driver owns that task handle and the queue-race policy; rendering
/// and terminal IO remain in NativeRuntime.

///|
pub(all) enum PromptSubmitOutcome {
  PromptIgnored
  PromptStarted
  PromptQueued
  PromptDeferred
  PromptQueueFull(Int)
  PromptQueueFailed(String)
} derive(Eq)

///|
pub extend PromptSubmitOutcome with Eq::{equal, not_equal}

///|
pub struct NativeTurnDriver {
  host : NativeHost
  editor : @ui.EditorModel
  mut turn : @async.Task[@posoco.TurnResult]?
  mut deferred_prompt : String?
}

///|
pub fn NativeTurnDriver::new(
  host : NativeHost,
  editor : @ui.EditorModel,
) -> NativeTurnDriver {
  { host, editor, turn: None, deferred_prompt: None, }
}

///|
pub fn NativeTurnDriver::host(self : NativeTurnDriver) -> NativeHost {
  self.host
}

///|
pub fn NativeTurnDriver::editor(
  self : NativeTurnDriver,
) -> @ui.EditorModel {
  self.editor
}

///|
pub fn NativeTurnDriver::is_running(self : NativeTurnDriver) -> Bool {
  self.turn is Some(_)
}

///|
fn NativeTurnDriver::spawn_fresh(
  self : NativeTurnDriver,
  group : @async.TaskGroup[Unit],
  prompt : String,
) -> Unit {
  let task = group.spawn(
    () => self.host.run_text_turn(prompt),
    allow_failure=true,
  )
  self.turn = Some(task)
}

///|
fn NativeTurnDriver::accepted_editor_submit(
  self : NativeTurnDriver,
  prompt : String,
) -> Unit {
  self.editor.record_history(prompt)
  self.editor.clear()
}

///|
/// Submit one editor value using the same running-turn policy as cetas-js.
///
/// A stale enqueue is not raced into a second concurrent Agent run. Instead
/// the prompt is retained internally and starts as a fresh turn immediately
/// after the current task is observed settled.
pub fn NativeTurnDriver::submit(
  self : NativeTurnDriver,
  group : @async.TaskGroup[Unit],
  raw_prompt : String,
) -> PromptSubmitOutcome {
  let prompt = raw_prompt.trim().to_owned()
  if prompt.is_empty() {
    self.editor.clear()
    return PromptIgnored
  }

  self.accepted_editor_submit(prompt)

  if !self.is_running() {
    self.spawn_fresh(group, prompt)
    return PromptStarted
  }

  match self.host.queue_follow_up(prompt) {
    @runtime.Accepted(..) => PromptQueued
    @runtime.RejectedStale(..) => {
      self.deferred_prompt = Some(prompt)
      PromptDeferred
    }
    @runtime.RejectedQueueFull(depth~) => {
      ignore(self.host.shell().append_error(
        "follow-up queue is full (" + depth.to_string() + "); wait for the turn to finish",
      ))
      PromptQueueFull(depth)
    }
    @runtime.RejectedQueueFailure(reason~) => {
      ignore(self.host.shell().append_error("follow-up queue failed: " + reason))
      PromptQueueFailed(reason)
    }
    @runtime.AbortAlreadyRequested => {
      let reason = "follow-up rejected: active turn is aborting"
      ignore(self.host.shell().append_error(reason))
      PromptQueueFailed(reason)
    }
  }
}

///|
fn NativeTurnDriver::failure_already_projected(
  self : NativeTurnDriver,
) -> Bool {
  let transcript = self.host.shell().transcript()
  let count = transcript.row_count()
  if count <= 0 {
    return false
  }
  let last = transcript.row(count - 1)
  last.kind == @ui.TranscriptError ||
    (last.kind == @ui.TranscriptSystem &&
      last.text == "⏹ interrupted")
}

///|
/// Observe completion without blocking the terminal loop.
///
/// True means the in-flight state changed. When a stale enqueue was deferred,
/// settlement immediately starts that prompt as a fresh turn.
pub fn NativeTurnDriver::poll_settle(
  self : NativeTurnDriver,
  group : @async.TaskGroup[Unit],
) -> Bool {
  guard self.turn is Some(task) else {
    return false
  }

  let result : Result[@posoco.TurnResult?, Error] = Ok(task.try_wait()) catch {
    error => Err(error)
  }

  match result {
    Ok(None) => false
    Ok(Some(_)) => {
      self.turn = None
      match self.deferred_prompt {
        Some(prompt) => {
          self.deferred_prompt = None
          self.spawn_fresh(group, prompt)
        }
        None => ()
      }
      true
    }
    Err(error) => {
      self.turn = None
      if !self.failure_already_projected() {
        self.host.shell().fail_turn(error.to_string())
      }
      match self.deferred_prompt {
        Some(prompt) => {
          self.deferred_prompt = None
          self.spawn_fresh(group, prompt)
        }
        None => ()
      }
      true
    }
  }
}

///|
pub fn NativeTurnDriver::interrupt(self : NativeTurnDriver) -> @runtime.EnqueueOutcome {
  self.host.interrupt_active()
}

///|
/// Cancel and drain the child task during process shutdown.
pub async fn NativeTurnDriver::cancel_and_wait(
  self : NativeTurnDriver,
) -> Unit {
  match self.turn {
    Some(task) => {
      task.cancel()
      try {
        let _ = task.wait()
      } catch {
        _ => ()
      }
      self.turn = None
    }
    None => ()
  }
  self.deferred_prompt = None
}

///|
pub async fn NativeTurnDriver::shutdown(self : NativeTurnDriver) -> Unit {
  self.cancel_and_wait()
  self.host.shutdown()
}
