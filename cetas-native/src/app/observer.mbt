/// Typed Posoco observer adapter for the native shell.
///
/// Production native composition should use this path so TurnEvent stays
/// MoonBit-native. The JSON parser remains a migration/parity seam shared with
/// cetas-js fixtures.

///|
pub struct NativeShellObserver {
  shell : NativeShell
}

///|
pub fn NativeShellObserver::new(shell : NativeShell) -> NativeShellObserver {
  { shell, }
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
fn tool_result_text(result : @posoco.ToolResult) -> String {
  match result {
    Success(content~, ..) => content
    ToolReportedError(content~, ..) => content
    RuntimeFailure(message~, ..) => message
    NotExecuted(..) => "not executed"
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
    @posoco.TurnEvent::ToolCallResult(call~, result~, is_error~) =>
      self.shell.tool_call_completed(
        call.call_id.to_string(),
        tool_result_text(result),
        is_error,
      )
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
