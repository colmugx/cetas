///|
/// output_wbtest.mbt — the StreamPrinter projection and the answer-block
/// normalization, driven directly with synthesized kernel events.

///|
fn tk_printer_reasoning_msg(
  text~ : String,
  reasoning~ : String,
) -> @posoco.Message {
  let message : @posoco.Message = AssistantMessage(
    content=[Text(text)],
    tool_calls=[],
    reasoning=Some({ content: reasoning, raw: None, }),
    finish_reason=Stop,
  )
  message
}

///|
test "text_block keeps the raw answer and ends with exactly one newline; empty prints nothing" {
  assert_eq(text_block("done one\n"), "done one\n")
  assert_eq(text_block("a\nb\n\n"), "a\nb\n")
  assert_eq(text_block("plain"), "plain\n")
  assert_eq(text_block(""), "")
  assert_eq(text_block("\n"), "")
  assert_eq(text_block("\n\n"), "")
}

///|
test "stream printer delivers text deltas only live, only under stream, and records any-delta state" {
  let cold = StreamPrinter::StreamPrinter(stream=false, show_thinking=false)
  let chunk : @posoco.StreamChunk = TextDelta(token="tok")
  cold.on_event_at(None, @posoco.TurnEvent::StreamChunkReceived(chunk~))
  assert_false(cold.streamed_text())
  let hot = StreamPrinter::StreamPrinter(stream=true, show_thinking=false)
  hot.on_event_at(None, @posoco.TurnEvent::StreamChunkReceived(chunk~))
  // No sink attached: deltas are display-only, nothing crashes or buffers.
  assert_false(hot.streamed_text())
  let delivered : Array[String] = []
  hot.set_text_sink(fn(token : String) { delivered.push(token) })
  hot.on_event_at(None, @posoco.TurnEvent::StreamChunkReceived(chunk~))
  assert_true(hot.streamed_text())
  assert_eq(delivered, ["tok"])
}

///|
test "stream printer routes reasoning deltas to the thinking sink only under stream+thinking" {
  let chunk : @posoco.StreamChunk = ReasoningDelta(token="thin")
  let deltas_only = StreamPrinter::StreamPrinter(
    stream=true,
    show_thinking=false,
  )
  let thinking_no_stream = StreamPrinter::StreamPrinter(
    stream=false,
    show_thinking=true,
  )
  let delivered : Array[String] = []
  deltas_only.set_thinking_sink(fn(token : String) { delivered.push(token) })
  thinking_no_stream.set_thinking_sink(fn(token : String) {
    delivered.push(token)
  })
  deltas_only.on_event_at(None, @posoco.TurnEvent::StreamChunkReceived(chunk~))
  thinking_no_stream.on_event_at(
    None,
    @posoco.TurnEvent::StreamChunkReceived(chunk~),
  )
  assert_eq(delivered, [])
  let live = StreamPrinter::StreamPrinter(stream=true, show_thinking=true)
  live.set_thinking_sink(fn(token : String) { delivered.push(token) })
  live.on_event_at(None, @posoco.TurnEvent::StreamChunkReceived(chunk~))
  assert_eq(delivered, ["thin"])
}

///|
test "stream printer records the latest committed reasoning block for the non-stream thinking face" {
  let printer = StreamPrinter::StreamPrinter(stream=false, show_thinking=true)
  printer.on_event_at(
    None,
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_printer_reasoning_msg(text="first", reasoning="first thought"),
      usage=None,
    ),
  )
  printer.on_event_at(
    None,
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_printer_reasoning_msg(text="second", reasoning="final thought"),
      usage=None,
    ),
  )
  assert_eq(printer.final_reasoning(), "final thought")
  // A response without reasoning leaves the last block in place.
  printer.on_event_at(
    None,
    @posoco.TurnEvent::ModelResponseReceived(
      message=@posoco.tk_user_msg("not an assistant message"),
      usage=None,
    ),
  )
  assert_eq(printer.final_reasoning(), "final thought")
}
