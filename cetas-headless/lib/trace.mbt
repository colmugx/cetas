///|
/// trace.mbt — the `--verbose` / `--stream` process trace (2026-09-08).
///
/// The human face of process visibility: a live, one-line-per-event trace of
/// what the agent is doing — thinking blocks, tool calls, tool results —
/// written to stderr so the stdout protocol lines (default face) and the
/// JSONL event stream (`--jsonl`) stay pure. Off by default.
///
/// Granularity: `--verbose` prints each committed unit the moment it
/// happens (a whole reasoning block, a tool call, a tool result); `--stream`
/// refines thinking/answer display to token deltas as they arrive. Either
/// way every unit is written when it completes — never batched to turn end.
///
/// Trace lines are single-line previews (`preview_cap` chars, whitespace
/// collapsed); the full record lives in the fs-session store, not here.
/// Delta display is telemetry: if the kernel dropped stream chunks the
/// committed block line still prints (a streamed block is closed, not
/// reprinted).

///|
pub struct TraceObserver {
  /// `--stream`: display thinking/text as token deltas as they arrive.
  stream : Bool
  /// Buffered trace pieces (exactly the text written); drained by tests.
  /// Empty in live mode — the sink receives each piece as it is built.
  mut writes : Array[String]
  /// Live sink: when attached, every piece is delivered here the moment it
  /// is built; otherwise it buffers above.
  mut sink : ((String) -> Unit)?
  /// A streamed reasoning block is open on the current line.
  mut in_reasoning : Bool
  /// A streamed text block is open on the current line.
  mut in_text : Bool
}

///|
pub fn TraceObserver::TraceObserver(stream? : Bool = false) -> TraceObserver {
  { stream, writes: [], sink: None, in_reasoning: false, in_text: false, }
}

///|
/// Attach the live sink (the loop's queue). After this, built pieces go to
/// the sink instead of the buffer.
pub fn TraceObserver::set_live_sink(
  self : TraceObserver,
  sink : (String) -> Unit,
) -> Unit {
  self.sink = Some(sink)
}

///|
/// Take the buffered pieces in order; the buffer is left empty. Only
/// meaningful without a live sink (buffered mode / tests).
pub fn TraceObserver::take_writes(self : TraceObserver) -> Array[String] {
  let out = self.writes
  self.writes = []
  out
}

///|
/// Deliver one built piece: to the live sink when attached, else to the
/// buffer.
fn TraceObserver::write(self : TraceObserver, text : String) -> Unit {
  match self.sink {
    Some(sink) => sink(text)
    None => self.writes.push(text)
  }
}

///|
/// One completed trace line (newline-terminated).
fn TraceObserver::write_line(self : TraceObserver, line : String) -> Unit {
  self.write(line + "\n")
}

///|
/// Fold the Text blocks of one content array into a single string.
fn text_blocks(content : Array[@posoco.Content]) -> String {
  let builder = StringBuilder()
  for block in content {
    match block {
      Text(t) => builder.write_string(t)
      _ => ()
    }
  }
  builder.to_string()
}

///|
/// A one-line clipped preview: whitespace collapsed, then char-clipped.
fn trace_preview(text : String) -> String {
  let (clipped, _) = clip_preview(single_line(text))
  clipped
}

///|
pub impl @posoco.Observer for TraceObserver with fn on_event_at(
  self,
  _scope : @posoco.EventScope?,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::ToolCallPending(call) =>
      self.write_line(
        "· call \{call.name.to_string()}(\{trace_preview(call.arguments.stringify())})",
      )
    @posoco.TurnEvent::ToolCallResult(call~, result~, ..) =>
      match result {
        Success(content~, ..) =>
          self.write_line(
            "· ok \{call.name.to_string()} (\{content.length()} chars)",
          )
        ToolReportedError(content~, ..) =>
          self.write_line(
            "· tool-error \{call.name.to_string()}: \{trace_preview(content)}",
          )
        RuntimeFailure(error_category~, message~) =>
          self.write_line(
            "· runtime-failure \{call.name.to_string()}: \{trace_preview("\{error_category}: \{message}")}",
          )
        NotExecuted(reason~, ..) =>
          self.write_line(
            "· not-executed \{call.name.to_string()}: \{trace_preview(reason.to_string())}",
          )
      }
    @posoco.TurnEvent::ModelResponseReceived(message~, ..) =>
      match message {
        AssistantMessage(content~, reasoning~, ..) => {
          // Close any streamed block first; a block whose deltas already
          // displayed is closed, not reprinted — the committed line is the
          // fallback for models that never streamed.
          let streamed_reasoning = self.in_reasoning
          let streamed_text = self.in_text
          if self.in_reasoning {
            self.write("\n")
            self.in_reasoning = false
          }
          if self.in_text {
            self.write("\n")
            self.in_text = false
          }
          match reasoning {
            Some(trace) =>
              if !streamed_reasoning {
                self.write_line(
                  "· thinking (\{trace.content.length()} chars): \{trace_preview(trace.content)}",
                )
              }
            None => ()
          }
          let text = text_blocks(content)
          if text.length() > 0 && !streamed_text {
            self.write_line("· text: \{trace_preview(text)}")
          }
        }
        _ => ()
      }
    @posoco.TurnEvent::StreamChunkReceived(chunk~) =>
      if self.stream {
        match chunk {
          ReasoningDelta(token~) => {
            if !self.in_reasoning {
              self.write("· thinking: ")
              self.in_reasoning = true
            }
            self.write(token)
          }
          TextDelta(token~) => {
            if !self.in_text {
              self.write("· text: ")
              self.in_text = true
            }
            self.write(token)
          }
          _ => ()
        }
      }
    @posoco.TurnEvent::StreamChunksDropped(count~) =>
      if self.stream {
        self.write_line("· [stream dropped \{count} chunks]")
      }
    _ => ()
  }
}

///|
/// Self-report the observer as an extension so it can ride `tail_exts` into
/// the composition (JsonlObserver registration precedent).
pub impl @posoco.Extension for TraceObserver with fn extension_id(_self) -> String {
  "cetas_headless_trace"
}

///|
pub impl @posoco.Extension for TraceObserver with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "cetas_headless_trace",
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
