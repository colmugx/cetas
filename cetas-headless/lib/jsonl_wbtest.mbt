///|
/// jsonl_wbtest.mbt — the JsonlObserver projection driven directly with
/// synthesized kernel events: tool_result lines (both error polarities),
/// per-turn usage windows, and the drained-buffer contract.

///|
fn tk_observer_call(name~ : String, call_id~ : String) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked(call_id),
    name: @posoco.ToolName::unchecked(name),
    arguments: Json::null(),
  }
}

///|
fn tk_observer_usage(input~ : Int, output~ : Int) -> @posoco.Usage {
  {
    input_tokens: Some(input),
    output_tokens: Some(output),
    total_tokens: Some(input + output),
    cached_input_tokens: None,
    uncached_input_tokens: None,
  }
}

///|
test "jsonl observer projects tool results with error polarity and folds usage" {
  let observer = JsonlObserver::JsonlObserver()
  observer.begin_turn(turn_no=3, session_id="s-3")
  observer.on_event_at(None, @posoco.TurnEvent::TurnStarted)
  observer.on_event_at(
    None,
    @posoco.TurnEvent::ToolCallResult(
      call=tk_observer_call(name="bash", call_id="c-9"),
      result=@posoco.tk_error_result("boom"),
      is_error=true,
    ),
  )
  observer.on_event_at(
    None,
    @posoco.TurnEvent::ToolCallResult(
      call=tk_observer_call(name="read", call_id="c-10"),
      result=@posoco.tk_ok_result("file body"),
      is_error=false,
    ),
  )
  observer.on_event_at(
    None,
    @posoco.TurnEvent::ModelResponseReceived(
      message=@posoco.tk_user_msg("ignored"),
      usage=Some(tk_observer_usage(input=4, output=2)),
    ),
  )
  observer.on_event_at(None, @posoco.TurnEvent::TurnCompleted)
  observer.emit_turn_completed(summary="all done", marker=turn_marker(3))
  assert_eq(observer.take_lines(), [
    "{\"type\":\"turn_started\",\"turn\":3,\"session\":\"s-3\"}", "{\"type\":\"tool_result\",\"turn\":3,\"name\":\"bash\",\"call_id\":\"c-9\",\"is_error\":true}",
    "{\"type\":\"tool_result\",\"turn\":3,\"name\":\"read\",\"call_id\":\"c-10\",\"is_error\":false}",
    "{\"type\":\"turn_completed\",\"turn\":3,\"summary\":\"all done\",\"marker\":\"[cetas-headless] turn 3 done\",\"usage\":{\"turns\":1,\"input_tokens\":4,\"output_tokens\":2}}",
  ])
  // Drained: the buffer is empty afterwards.
  assert_eq(observer.take_lines().length(), 0)
}

///|
test "jsonl observer resets the usage window at each begin_turn and reports absent usage as zeros" {
  let observer = JsonlObserver::JsonlObserver()
  observer.begin_turn(turn_no=1, session_id="s-1")
  observer.on_event_at(
    None,
    @posoco.TurnEvent::ModelResponseReceived(
      message=@posoco.tk_user_msg("m"),
      usage=Some(tk_observer_usage(input=100, output=50)),
    ),
  )
  observer.on_event_at(
    None,
    @posoco.TurnEvent::ModelResponseReceived(
      message=@posoco.tk_user_msg("m"),
      usage=Some(tk_observer_usage(input=10, output=5)),
    ),
  )
  observer.emit_turn_failed(error="late failure", marker=turn_marker(1))
  assert_eq(observer.take_lines(), [
    "{\"type\":\"turn_failed\",\"turn\":1,\"error\":\"late failure\",\"marker\":\"[cetas-headless] turn 1 done\"}",
  ])
  // New turn: window resets; a response without usage stays at zeros
  // (unknown usage is never coerced, but the wire schema is ints).
  observer.begin_turn(turn_no=2, session_id="s-1")
  observer.on_event_at(
    None,
    @posoco.TurnEvent::ModelResponseReceived(
      message=@posoco.tk_user_msg("m"),
      usage=None,
    ),
  )
  observer.emit_turn_completed(summary="ok", marker=turn_marker(2))
  assert_eq(observer.take_lines(), [
    "{\"type\":\"turn_completed\",\"turn\":2,\"summary\":\"ok\",\"marker\":\"[cetas-headless] turn 2 done\",\"usage\":{\"turns\":0,\"input_tokens\":0,\"output_tokens\":0}}",
  ])
}

///|
test "jsonl observer escapes wire-breaking characters through the json encoder" {
  let observer = JsonlObserver::JsonlObserver()
  observer.begin_turn(turn_no=1, session_id="s\"1")
  observer.emit_turn_completed(
    summary="said \"hi\"\nnewline",
    marker=turn_marker(1),
  )
  let lines = observer.take_lines()
  assert_eq(lines.length(), 1)
  assert_true(lines[0].has_prefix("{\"type\":\"turn_completed\",\"turn\":1,"))
  // Round-trip through a real JSON parser: whatever the encoder's escape
  // style, the line must parse back to the exact values.
  let parsed : Json = @json.parse(lines[0])
  let fields = match parsed {
    Object(map) => map
    _ => fail("event line must be a json object")
  }
  assert_eq(
    fields.get("summary").map(fn(j : Json) { j.stringify() }),
    Some("\"said \\\"hi\\\"\\nnewline\""),
  )
  assert_eq(
    fields.get("marker").map(fn(j : Json) { j.stringify() }),
    Some("\"[cetas-headless] turn 1 done\""),
  )
  assert_true(fields.get("session") is None)
}

///|
async test "the jsonl observer rides tail_exts into the composition and receives kernel events" {
  let observer = JsonlObserver::JsonlObserver()
  let (agent, _model) = tk_scripted_agent(
    [@posoco.Respond(@posoco.tk_stop_response("hey"))],
    tail_exts=[observer as &@posoco.Extension],
  )
  observer.begin_turn(turn_no=1, session_id="cetas-attach")
  let _ = @cetas_core.run_prompt(agent, "hello", "cetas-attach")
  // Kernel projection: TurnStarted buffers a line; TurnCompleted only ticks
  // the usage counter (the terminal line is loop-side, see the loop tests).
  assert_eq(observer.take_lines(), [
    "{\"type\":\"turn_started\",\"turn\":1,\"session\":\"cetas-attach\"}",
  ])
  assert_eq(observer.turns_completed, 1)
}
