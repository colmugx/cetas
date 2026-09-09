///|
/// output.mbt — the clean-stdout text faces (2026-09-08 stdout purity).
///
/// In text modes stdout carries ONLY the answer: the default face prints the
/// final answer as one block (raw text, a single trailing newline, empty
/// answer prints nothing); `--stream` prints TextDelta chunks as they arrive
/// (raw, no prefixes) and closes with one trailing newline. Everything else
/// — session line, marker, failures, thinking, the verbose event log — goes
/// to stderr. `StreamPrinter` is the live printing observer for those two
/// faces; it rides `tail_exts` like the jsonl observer and receives the same
/// `TurnEvent::StreamChunkReceived` events the kernel dispatches per turn.

///|
/// Collapse a projected answer/reasoning text into its stdout block shape:
/// raw text with exactly one trailing newline; an empty (or newline-only)
/// text yields "" — nothing is printed for an empty answer.
pub fn text_block(text : String) -> String {
  let chars : Array[Char] = []
  for ch in text {
    chars.push(ch)
  }
  while chars.length() > 0 && chars[chars.length() - 1] == '\n' {
    ignore(chars.pop())
  }
  if chars.is_empty() {
    ""
  } else {
    let builder = StringBuilder()
    for ch in chars {
      builder.write_char(ch)
    }
    builder.write_char('\n')
    builder.to_string()
  }
}

///|
pub struct StreamPrinter {
  /// `--stream`: text deltas stream to the stdout sink as they arrive.
  stream : Bool
  /// `--show-thinking`: reasoning goes to stderr (live deltas under
  /// `stream`, else the final committed block dumped by the loop).
  show_thinking : Bool
  /// stdout sink for text deltas — attached by the loop's live queue.
  mut text_sink : ((String) -> Unit)?
  /// stderr sink for reasoning deltas — attached by the loop's live queue.
  mut thinking_sink : ((String) -> Unit)?
  /// Whether any text delta was written; gates the stream-mode trailing
  /// newline and the non-streaming-provider fallback to the answer block.
  mut streamed_text : Bool
  /// The latest committed reasoning block (non-stream thinking face).
  mut final_reasoning : String
}

///|
pub fn StreamPrinter::StreamPrinter(
  stream~ : Bool,
  show_thinking~ : Bool,
) -> StreamPrinter {
  {
    stream,
    show_thinking,
    text_sink: None,
    thinking_sink: None,
    streamed_text: false,
    final_reasoning: "",
  }
}

///|
/// Attach the stdout delta sink (the loop's live stdout queue).
pub fn StreamPrinter::set_text_sink(
  self : StreamPrinter,
  sink : (String) -> Unit,
) -> Unit {
  self.text_sink = Some(sink)
}

///|
/// Attach the stderr delta sink (the loop's live stderr queue).
pub fn StreamPrinter::set_thinking_sink(
  self : StreamPrinter,
  sink : (String) -> Unit,
) -> Unit {
  self.thinking_sink = Some(sink)
}

///|
/// Whether any text delta was written during the turn.
pub fn StreamPrinter::streamed_text(self : StreamPrinter) -> Bool {
  self.streamed_text
}

///|
/// The latest committed reasoning block seen this turn.
pub fn StreamPrinter::final_reasoning(self : StreamPrinter) -> String {
  self.final_reasoning
}

///|
pub impl @posoco.Observer for StreamPrinter with fn on_event_at(
  self,
  _scope : @posoco.EventScope?,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::StreamChunkReceived(chunk~) =>
      match chunk {
        TextDelta(token~) =>
          if self.stream {
            match self.text_sink {
              Some(sink) => {
                self.streamed_text = true
                sink(token)
              }
              None => ()
            }
          }
        ReasoningDelta(token~) =>
          if self.stream && self.show_thinking {
            match self.thinking_sink {
              Some(sink) => sink(token)
              None => ()
            }
          }
        _ => ()
      }
    @posoco.TurnEvent::ModelResponseReceived(message~, ..) =>
      match message {
        AssistantMessage(reasoning~, ..) =>
          match reasoning {
            Some(trace) => self.final_reasoning = trace.content
            None => ()
          }
        _ => ()
      }
    _ => ()
  }
}

///|
/// Self-report the observer as an extension so it can ride `tail_exts` into
/// the composition (JsonlObserver registration precedent).
pub impl @posoco.Extension for StreamPrinter with fn extension_id(_self) -> String {
  "cetas_headless_stream"
}

///|
pub impl @posoco.Extension for StreamPrinter with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "cetas_headless_stream",
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
