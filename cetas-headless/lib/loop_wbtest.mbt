///|
/// loop_wbtest.mbt — the one-shot protocol over the full cetas-core
/// assembly with a scripted model: one resolved task → one turn → session
/// line + summary + marker on the captured sink; a failed turn still emits
/// the marker and reports failure; peer envelopes still wrap; the --jsonl
/// face emits the frozen event sequence and nothing else.

///|
/// A scripted stdin reader: `lines` are consumed in order, then EOF. The
/// cell records how often the reader was polled.
fn tk_reader(
  lines : Array[String],
) -> (async () -> String? noraise, Array[Int]) {
  let cursor : Array[Int] = [0]
  let calls : Array[Int] = [0]
  let read_line = async fn() noraise {
    calls[0] = calls[0] + 1
    if cursor[0] < lines.length() {
      let line = lines[cursor[0]]
      cursor[0] = cursor[0] + 1
      Some(line)
    } else {
      None
    }
  }
  (read_line, calls)
}

///|
/// A captured stdout sink: every protocol line written lands in the array.
fn tk_sink() -> (async (String) -> Unit noraise, Array[String]) {
  let out : Array[String] = []
  let write_out = async fn(text : String) noraise { out.push(text) }
  (write_out, out)
}

///|
/// A stop response carrying provider usage — for the jsonl usage assertion.
fn tk_usage_response(
  text : String,
  input~ : Int,
  output~ : Int,
) -> @posoco.ModelCallResult {
  let completion : @posoco.Completion = @posoco.Completion::Completion(
    content=[Text(text)],
    tool_calls=[],
    reasoning=None,
    finish_reason=Stop,
    usage=Some({
      input_tokens: Some(input),
      output_tokens: Some(output),
      total_tokens: Some(input + output),
      cached_input_tokens: None,
      uncached_input_tokens: None,
    }),
  )
  { completion, processed_messages: [], }
}

///|
/// Pull the text of the last user message of a call (the prompt is the
/// newest user turn the model received; history precedes it).
fn tk_last_user_text(messages : Array[@posoco.Message]) -> String {
  let builder = StringBuilder()
  for message in messages {
    match message {
      UserMessage(content~) =>
        for block in content {
          match block {
            Text(t) => {
              builder.write_string(t)
              builder.write_char('\n')
            }
            _ => ()
          }
        }
      _ => ()
    }
  }
  builder.to_string()
}

///|
async test "one-shot happy path: session line, summary, marker in pinned order" {
  let (agent, _model) = tk_scripted_agent([
    @posoco.Respond(@posoco.tk_stop_response("done one")),
  ])
  let (write_out, out) = tk_sink()
  let failed = run_one_turn(
    agent~,
    session_id="cetas-once",
    task="first task",
    jsonl=None,
    write_out~,
  )
  assert_false(failed)
  assert_eq(out, [
    "session: cetas-once\n", "[cetas-headless] turn 1: done one\n", "[cetas-headless] turn 1 done\n",
  ])
}

///|
async test "one-shot failed turn: failed summary line, marker still emitted, failure returned" {
  // No scripted steps: the model is exhausted and the turn fails.
  let (agent, _model) = tk_scripted_agent([])
  let (write_out, out) = tk_sink()
  let failed = run_one_turn(
    agent~,
    session_id="cetas-once",
    task="doomed task",
    jsonl=None,
    write_out~,
  )
  assert_true(failed)
  assert_eq(out.length(), 3)
  assert_eq(out[0], "session: cetas-once\n")
  assert_true(out[1].has_prefix("[cetas-headless] turn 1 failed: "))
  assert_eq(out[2], "[cetas-headless] turn 1 done\n")
}

///|
async test "resolve_task: an argv task wins and stdin is never polled" {
  let (read_line, calls) = tk_reader([])
  let task = resolve_task(Some("explicit task"), read_line~)
  assert_eq(task, Some("explicit task"))
  assert_eq(calls[0], 0)
}

///|
async test "resolve_task: exactly one stdin line is read when no argv task" {
  let (read_line, calls) = tk_reader(["piped task\n", "never read"])
  let task = resolve_task(None, read_line~)
  assert_eq(task, Some("piped task"))
  assert_eq(calls[0], 1)
}

///|
async test "resolve_task: eof, blank stdin line, and blank argv task yield None" {
  let (eof_reader, eof_calls) = tk_reader([])
  assert_true(resolve_task(None, read_line=eof_reader) is None)
  assert_eq(eof_calls[0], 1)
  let (blank_reader, blank_calls) = tk_reader(["   \n"])
  assert_true(resolve_task(None, read_line=blank_reader) is None)
  assert_eq(blank_calls[0], 1)
  let (unused_reader, unused_calls) = tk_reader([])
  assert_true(resolve_task(Some("   "), read_line=unused_reader) is None)
  assert_eq(unused_calls[0], 0)
}

///|
async test "peer envelope task wraps the task in a low-trust herdr-peer context; plain task passes through" {
  let (agent, model) = tk_scripted_agent([
    @posoco.Respond(@posoco.tk_stop_response("done")),
    @posoco.Respond(@posoco.tk_stop_response("done")),
  ])
  let (write_out, out) = tk_sink()
  assert_false(
    run_one_turn(
      agent~,
      session_id="cetas-peer-test",
      task="[cetas-peer from=pane-9 session=cetas-abc] refactor the loop",
      jsonl=None,
      write_out~,
    ),
  )
  assert_false(
    run_one_turn(
      agent~,
      session_id="cetas-peer-test",
      task="plain task",
      jsonl=None,
      write_out~,
    ),
  )
  assert_eq(model.call_count(), 2)
  // Envelope task: the newest user message is the envelope — attribution
  // visible to the model, trust=false, task text inside the envelope.
  let turn1 = model.received_messages[0]
  let wrapped = tk_last_user_text([turn1[turn1.length() - 1]])
  assert_true(
    wrapped.has_prefix(
      "<herdr-peer-context type=\"task\" trust=\"false\" source=\"pane-9\" peer_session=\"cetas-abc\">",
    ),
  )
  assert_true(wrapped.contains("refactor the loop"))
  assert_true(wrapped.has_suffix("</herdr-peer-context>\n"))
  // Plain task: reaches the model verbatim as the newest user turn.
  let turn2 = model.received_messages[1]
  assert_eq(tk_last_user_text([turn2[turn2.length() - 1]]), "plain task\n")
  // The human face still shows the session line and the plain summary.
  assert_eq(out.length(), 6)
  assert_eq(out[0], "session: cetas-peer-test\n")
  assert_eq(out[1], "[cetas-headless] turn 1: done\n")
  assert_eq(out[2], "[cetas-headless] turn 1 done\n")
}

///|
async test "jsonl single-turn happy path: the frozen event sequence with usage folded into turn_completed, and no session line" {
  let observer = JsonlObserver::JsonlObserver()
  let (agent, _model) = tk_scripted_agent(
    [@posoco.Respond(tk_usage_response("done one", input=11, output=7))],
    tail_exts=[observer as &@posoco.Extension],
  )
  let (write_out, out) = tk_sink()
  let failed = run_one_turn(
    agent~,
    session_id="cetas-jsonl",
    task="first task",
    jsonl=Some(observer),
    write_out~,
  )
  assert_false(failed)
  // run_prompt's text projection appends one newline per text block, so the
  // summary carries a trailing (json-escaped) \n. The session rides the
  // turn_started event only — nothing else is written.
  assert_eq(out, [
    "{\"type\":\"turn_started\",\"turn\":1,\"session\":\"cetas-jsonl\"}\n", "{\"type\":\"turn_completed\",\"turn\":1,\"summary\":\"done one\\n\",\"marker\":\"[cetas-headless] turn 1 done\",\"usage\":{\"turns\":1,\"input_tokens\":11,\"output_tokens\":7}}\n",
  ])
}

///|
async test "jsonl single-turn failure path: turn_failed carries the marker and failure is returned" {
  let observer = JsonlObserver::JsonlObserver()
  // No scripted steps: the model is exhausted and the turn fails.
  let (agent, _model) = tk_scripted_agent([], tail_exts=[
    observer as &@posoco.Extension,
  ])
  let (write_out, out) = tk_sink()
  let failed = run_one_turn(
    agent~,
    session_id="cetas-jsonl",
    task="doomed turn",
    jsonl=Some(observer),
    write_out~,
  )
  assert_true(failed)
  assert_eq(out.length(), 2)
  assert_eq(
    out[0],
    "{\"type\":\"turn_started\",\"turn\":1,\"session\":\"cetas-jsonl\"}\n",
  )
  assert_true(
    out[1].has_prefix("{\"type\":\"turn_failed\",\"turn\":1,\"error\":\""),
  )
  assert_true(out[1].contains("\"marker\":\"[cetas-headless] turn 1 done\""))
  // No usage object on turn_failed (frozen schema: error + marker only).
  assert_false(out[1].contains("\"usage\""))
}

///|
test "the marker and single-line helpers are protocol-stable" {
  assert_eq(turn_marker(7), "[cetas-headless] turn 7 done")
  assert_eq(single_line("a\nb\r  c\td"), "a b c d")
  assert_eq(single_line("plain"), "plain")
}
