///|
/// trace_wbtest.mbt — the TraceObserver projection driven directly with
/// synthesized kernel events: committed process lines (event granularity),
/// streamed token blocks (--stream granularity), the streamed-block close
/// without reprint, and the chunk-drop note.

///|
fn tk_trace_call(name~ : String, call_id~ : String) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked(call_id),
    name: @posoco.ToolName::unchecked(name),
    arguments: Json::object(Map::from_array([("path", Json::string("a.mbt"))])),
  }
}

///|
test "trace observer renders the committed process: thinking, call, outcome lines" {
  let observer = TraceObserver::TraceObserver()
  observer.on_event_at(
    None,
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_reasoning_msg(
        text="checking",
        reasoning="look at the file\nfirst",
      ),
      usage=None,
    ),
  )
  observer.on_event_at(
    None,
    @posoco.TurnEvent::ToolCallPending(
      tk_trace_call(name="read", call_id="c-1"),
    ),
  )
  observer.on_event_at(
    None,
    @posoco.TurnEvent::ToolCallResult(
      call=tk_trace_call(name="read", call_id="c-1"),
      result=@posoco.tk_ok_result("one two three"),
      is_error=false,
    ),
  )
  observer.on_event_at(
    None,
    @posoco.TurnEvent::ToolCallResult(
      call=tk_trace_call(name="bash", call_id="c-2"),
      result=@posoco.tk_error_result("exit 1\nbad"),
      is_error=true,
    ),
  )
  assert_eq(observer.take_writes(), [
    "· thinking (22 chars): look at the file first\n", "· text: checking\n", "· call read({\"path\":\"a.mbt\"})\n",
    "· ok read (13 chars)\n", "· tool-error bash: exit 1 bad\n",
  ])
}

///|
test "trace observer streams deltas as one live block and closes it at commit without reprint" {
  let observer = TraceObserver::TraceObserver(stream=true)
  let r1 : @posoco.StreamChunk = ReasoningDelta(token="thin")
  let r2 : @posoco.StreamChunk = ReasoningDelta(token="king")
  observer.on_event_at(None, @posoco.TurnEvent::StreamChunkReceived(chunk=r1))
  observer.on_event_at(None, @posoco.TurnEvent::StreamChunkReceived(chunk=r2))
  observer.on_event_at(
    None,
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_reasoning_msg(text="", reasoning="thinking"),
      usage=None,
    ),
  )
  assert_eq(observer.take_writes(), ["· thinking: ", "thin", "king", "\n"])
}

///|
test "trace observer falls back to the committed line when a streaming model never sent deltas" {
  let observer = TraceObserver::TraceObserver(stream=true)
  observer.on_event_at(
    None,
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_reasoning_msg(text="answer", reasoning="quiet reasoning"),
      usage=None,
    ),
  )
  assert_eq(observer.take_writes(), [
    "· thinking (15 chars): quiet reasoning\n", "· text: answer\n",
  ])
}

///|
test "trace observer notes dropped stream chunks and ignores deltas without stream" {
  let streaming = TraceObserver::TraceObserver(stream=true)
  streaming.on_event_at(None, @posoco.TurnEvent::StreamChunksDropped(count=7))
  assert_eq(streaming.take_writes(), ["· [stream dropped 7 chunks]\n"])
  let plain = TraceObserver::TraceObserver()
  plain.on_event_at(None, @posoco.TurnEvent::StreamChunksDropped(count=7))
  let chunk : @posoco.StreamChunk = TextDelta(token="tok")
  plain.on_event_at(None, @posoco.TurnEvent::StreamChunkReceived(chunk~))
  assert_eq(plain.take_writes().length(), 0)
}

///|
test "trace observer live sink receives each piece the moment it is built" {
  let observer = TraceObserver::TraceObserver()
  let delivered : Array[String] = []
  observer.set_live_sink(fn(text : String) { delivered.push(text) })
  observer.on_event_at(
    None,
    @posoco.TurnEvent::ToolCallPending(
      tk_trace_call(name="read", call_id="c-1"),
    ),
  )
  assert_eq(delivered, ["· call read({\"path\":\"a.mbt\"})\n"])
  assert_eq(observer.take_writes().length(), 0)
}
