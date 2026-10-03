/// Typed Posoco observer adapter for the native shell.
///
/// Production native composition should use this path so TurnEvent stays
/// MoonBit-native. The JSON parser remains a migration/parity seam shared with
/// cetas-js fixtures.

///|
pub struct NativeShellObserver {
  shell : NativeShell
  session_state : NativeSessionState?
}

///|
pub fn NativeShellObserver::new(
  shell : NativeShell,
  session_state? : NativeSessionState? = None,
) -> NativeShellObserver {
  { shell, session_state, }
}

///|
fn assistant_message_payload(
  message : @posoco.Message,
) -> (String, String)? {
  match message {
    AssistantMessage(content~, reasoning~, ..) => {
      let text_parts : Array[String] = []
      for block in content {
        match block {
          @posoco.Content::Text(text) => text_parts.push(text)
          @posoco.Content::Image(..) => ()
        }
      }
      let reasoning_text = match reasoning {
        Some(value) => value.content
        None => ""
      }
      Some((reasoning_text, text_parts[:].join("\n\n")))
    }
    _ => None
  }
}

///|
pub impl @posoco.Observer for NativeShellObserver with fn on_event(
  self,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::TurnStarted => self.shell.begin_turn()
    @posoco.TurnEvent::TurnCompleted => self.shell.end_turn()
    @posoco.TurnEvent::TurnFailed(message) => self.shell.fail_turn(message)
    @posoco.TurnEvent::ModelResponseReceived(message~, ..) =>
      match assistant_message_payload(message) {
        Some((reasoning, text)) => self.shell.message_end(reasoning, text)
        None => ()
      }
    @posoco.TurnEvent::ToolCallPending(call) =>
      self.shell.tool_call_started(
        call.call_id.to_string(),
        call.name.to_string(),
        call.arguments.stringify(),
      )
    @posoco.TurnEvent::ToolCallSucceeded(call~, content~, ..) =>
      self.shell.tool_call_completed(
        call.call_id.to_string(),
        content,
        false,
      )
    @posoco.TurnEvent::ToolCallFailed(call~, failure~) => {
      let result = match failure {
        ReportedError(content~, ..) => content
        Runtime(message~, ..) => message
      }
      self.shell.tool_call_completed(
        call.call_id.to_string(),
        result,
        true,
      )
    }
    @posoco.TurnEvent::ToolCallRejected(call~, ..) =>
      self.shell.tool_call_completed(
        call.call_id.to_string(),
        "not executed",
        true,
      )
    @posoco.TurnEvent::ToolCallAbandoned(call~, ..) =>
      self.shell.tool_call_completed(
        call.call_id.to_string(),
        "abandoned",
        true,
      )
    @posoco.TurnEvent::SessionRedirect(from~, to~, ..) => {
      self.shell.session_redirect(from, to)
      match self.session_state {
        Some(state) => ignore(state.adopt_redirect(to))
        None => ()
      }
    }
    @posoco.TurnEvent::CompactStarted(trigger~) =>
      self.shell.compact_started(trigger)
    @posoco.TurnEvent::CompactFinished(mode~, messages_after~, ..) =>
      self.shell.compact_finished(mode, messages_after)
    @posoco.TurnEvent::OperationFinalized(operation~, outcome~, detail~) =>
      self.shell.operation_finalized(operation, outcome, detail)
    @posoco.TurnEvent::StreamChunkReceived(chunk~) =>
      match chunk {
        @posoco.StreamChunk::TextDelta(token~) =>
          self.shell.append_text(token)
        @posoco.StreamChunk::ReasoningDelta(token~) =>
          self.shell.append_reasoning(token)
        @posoco.StreamChunk::ToolCallDelta(
          index~,
          id~,
          name~,
          arguments_delta~
        ) =>
          self.shell.tool_args_delta(index, id, name, arguments_delta)
        @posoco.StreamChunk::Usage(..) | @posoco.StreamChunk::Finish(..) => ()
      }
    _ => ()
  }
}

///|
pub impl @posoco.Extension for NativeShellObserver with fn extension_id(
  _self : NativeShellObserver,
) -> String {
  "cetas_native_observer"
}

///|
pub impl @posoco.Extension for NativeShellObserver with fn manifest(
  self : NativeShellObserver,
) -> @posoco.ExtensionManifest {
  let manifest = @posoco.ExtensionManifest::default(id="cetas_native_observer")
  { ..manifest, observers: [self], }
}

///|
pub extend NativeShellObserver with @posoco.Observer::{on_event, on_event_at}

///|
pub extend NativeShellObserver with @posoco.Extension::{extension_id, manifest}

///|
pub fn typed_observer_validation_marker() -> Int {
  let shell = NativeShell::new()
  let observer = NativeShellObserver::new(shell)

  observer.on_event(@posoco.TurnEvent::TurnStarted)

  let reasoning : @posoco.StreamChunk = ReasoningDelta(token="r")
  observer.on_event(
    @posoco.TurnEvent::StreamChunkReceived(chunk=reasoning),
  )

  let text : @posoco.StreamChunk = TextDelta(token="a")
  observer.on_event(
    @posoco.TurnEvent::StreamChunkReceived(chunk=text),
  )

  observer.on_event(@posoco.TurnEvent::TurnCompleted)

  let lifecycle_shell = NativeShell::new()
  let lifecycle_observer = NativeShellObserver::new(lifecycle_shell)
  lifecycle_observer.on_event(
    @posoco.TurnEvent::CompactStarted(trigger="manual"),
  )
  lifecycle_observer.on_event(
    @posoco.TurnEvent::CompactFinished(
      trigger="manual",
      mode="Replace",
      final_session_id="s1",
      messages_after=3,
    ),
  )
  lifecycle_observer.on_event(
    @posoco.TurnEvent::OperationFinalized(
      operation="compact",
      outcome="cancelled",
      detail="compact cancelled",
    ),
  )
  if lifecycle_shell.status() != ShellWorking("compacting (manual)") ||
    lifecycle_shell.finalized_operation_count() != 1 ||
    lifecycle_shell.termination_notice_count() != 1 ||
    lifecycle_shell.transcript().row_count() != 2 ||
    lifecycle_shell.transcript().row(0).text !=
      "context compacted (Replace, 3 messages)" ||
    lifecycle_shell.transcript().row(1).text != "⏹ compact interrupted" {
    return 0
  }

  let redirected_shell = NativeShell::new()
  let state = NativeSessionState::new("s_old")
  let redirected = NativeShellObserver::new(
    redirected_shell,
    session_state=Some(state),
  )
  redirected.on_event(
    @posoco.TurnEvent::SessionRedirect(
      from="s_old",
      to="s_new",
      messages_before=2,
      messages_after=1,
    ),
  )
  if state.session_id() != "s_new" ||
    redirected_shell.transcript().row_count() != 1 ||
    redirected_shell.transcript().row(0).text != "↻ redirect: s_old → s_new" {
    return 0
  }

  if shell.status() != ShellIdle ||
    shell.transcript().row_count() != 2 ||
    shell.transcript().row(0).text != "r" ||
    shell.transcript().row(1).text != "a" ||
    !shell.transcript().row(0).finalized ||
    !shell.transcript().row(1).finalized {
    0
  } else {
    1
  }
}
