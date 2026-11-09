///|
/// Native terminal UI — delegation and non-blocking question seam.
///
/// Every assertion below is about what actually reaches the sink (the native
/// host's realtime channel) and about what must *not* reach it: child facts
/// never enter the parent transcript/ledger, and the default console gets none
/// of these frames at all.

///|
fn native_decode(raw : Array[String]) -> Array[Map[String, Json]] {
  raw.map(frame => {
    let parsed = @json.parse(frame) catch {
      _ => abort("native frame must be a JSON object")
    }
    match parsed {
      Json::Object(fields) => fields
      _ => abort("native frame must be a JSON object")
    }
  })
}

///|
fn native_frame_string(fields : Map[String, Json], key : String) -> String {
  match fields.get(key) {
    Some(Json::String(value)) => value
    _ => ""
  }
}

///|
/// One child fact as the subagent extension emits it.
fn native_child_event(
  event : @posoco.TurnEvent,
  child_session~ : String = "subagent-1",
  kind~ : String = "explore",
  parent_call~ : String = "call-7",
) -> @subagent_kit.SubagentEvent {
  { child_session, kind, parent_call, event, }
}

///|
/// A child turn finishing is a `turn` phase kernel fact; the extension's
/// `background_terminal` is a `lifecycle` phase task terminal. They must never
/// collapse into one another: only the terminal carries the final state.
test "native child events keep attribution and separate turn from terminal" {
  let hub = EventHub::new()
  let raw : Array[String] = []
  hub.attach(fn(frame) { raw.push(frame) })
  let sink = match native_subagent_sink(hub, "session-a", native_ui=true) {
    Some(sink) => sink
    None => fail("native projection must subscribe a child-event sink")
  }
  sink(native_child_event(@posoco.TurnEvent::TurnCompleted))
  sink(
    native_child_event(
      @posoco.TurnEvent::Custom(
        source="posoco_ext_subagent",
        label="background_terminal",
        data=Json::object({
          "child_session": Json::string("subagent-1"),
          "kind": Json::string("explore"),
          "state": Json::string("completed"),
          "summary": Json::string("all reads done"),
          "task_id": Json::string("task-1"),
          "superseded": Json::boolean(false),
        }),
      ),
    ),
  )
  let frames = native_decode(raw)
  assert_eq(frames.length(), 2)
  let turn = frames[0]
  assert_eq(native_frame_string(turn, "type"), "subagent.event")
  assert_eq(native_frame_string(turn, "session_id"), "session-a")
  assert_eq(native_frame_string(turn, "child_session"), "subagent-1")
  assert_eq(native_frame_string(turn, "kind"), "explore")
  assert_eq(native_frame_string(turn, "parent_call"), "call-7")
  assert_eq(native_frame_string(turn, "phase"), "turn")
  assert_eq(
    turn["ev"],
    Json::object(Map::from_array([("type", Json::string("turn.completed"))])),
  )
  let terminal = frames[1]
  assert_eq(native_frame_string(terminal, "phase"), "lifecycle")
  let ev = match terminal["ev"] {
    Json::Object(ev) => ev
    _ => abort("child ev must be an object")
  }
  assert_eq(native_frame_string(ev, "type"), "custom")
  assert_eq(native_frame_string(ev, "source"), "posoco_ext_subagent")
  assert_eq(native_frame_string(ev, "label"), "background_terminal")
  match ev["data"] {
    Json::Object(data) => {
      assert_eq(native_frame_string(data, "state"), "completed")
      assert_eq(native_frame_string(data, "task_id"), "task-1")
    }
    _ => abort("custom data must be an object")
  }
}

///|
/// A child tool lifecycle keeps the native field names the parent renderer
/// already understands, including structured results and attachments.
test "native child tool events carry the native lifecycle shape" {
  let call : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("call-c1"),
    name: @posoco.ToolName::unchecked("read"),
    arguments: Json::object({ "path": Json::string("a.txt") }),
  }
  let events : Array[@posoco.TurnEvent] = [
    @posoco.TurnEvent::StreamChunkReceived(
      chunk=@posoco.StreamChunk::ToolCallDelta(
        index=0,
        id=Some("call-c1"),
        name=Some("read"),
        arguments_delta=Some("{\"path\":"),
      ),
    ),
    @posoco.TurnEvent::ToolCallStarted(call~),
    @posoco.TurnEvent::ToolCallSucceeded(
      call~,
      content="body",
      structured=Some({ "summary": Json::string("read ok") }),
      attachments=[@posoco.Content::Image(media_type="image/png", data="aW8=")],
    ),
    @posoco.TurnEvent::ToolCallFailed(
      call~,
      failure=Runtime(category="adapter", message="io broke"),
    ),
  ]
  let projected : Array[Json] = []
  for event in events {
    match native_child_ev_json(event) {
      Some(ev) => projected.push(ev)
      None => ()
    }
  }
  assert_eq(projected.length(), 4)
  assert_eq(
    projected[0],
    Json::object(
      Map::from_array([
        ("type", Json::string("tool.args_delta")),
        ("index", Json::number(0.0)),
        ("id", Json::string("call-c1")),
        ("name", Json::string("read")),
        ("delta", Json::string("{\"path\":")),
      ]),
    ),
  )
  let succeeded = match projected[2] {
    Json::Object(fields) => fields
    _ => abort("ev must be an object")
  }
  assert_eq(native_frame_string(succeeded, "type"), "tool.succeeded")
  assert_eq(native_frame_string(succeeded, "tool_call_id"), "call-c1")
  assert_eq(native_frame_string(succeeded, "result"), "body")
  assert_eq(succeeded["is_error"], Json::boolean(false))
  assert_eq(
    succeeded["structured"],
    Json::object({ "summary": Json::string("read ok") }),
  )
  assert_eq(
    succeeded["attachments"],
    Json::array([
      Json::object(
        Map::from_array([
          ("type", Json::string("image")),
          ("media_type", Json::string("image/png")),
          ("data", Json::string("aW8=")),
        ]),
      ),
    ]),
  )
  let failed = match projected[3] {
    Json::Object(fields) => fields
    _ => abort("ev must be an object")
  }
  assert_eq(native_frame_string(failed, "failure_kind"), "runtime")
  assert_eq(native_frame_string(failed, "error_category"), "adapter")
}

///|
/// Child-local projection facts carry nothing the parent surface can render,
/// so they are dropped instead of becoming unknown-frame noise.
test "native child projection drops child-local facts" {
  let events : Array[@posoco.TurnEvent] = [
    @posoco.TurnEvent::CompactStarted(trigger="auto"),
    @posoco.TurnEvent::OperationFinalized(
      operation="compact",
      outcome="completed",
      detail="",
    ),
    @posoco.TurnEvent::StreamChunksDropped(count=2),
    @posoco.TurnEvent::ConfigChanged(
      field="model",
      old_value="a",
      new_value="b",
    ),
    @posoco.TurnEvent::ModelRequestStarted,
  ]
  for event in events {
    assert_true(native_child_ev_json(event) is None)
  }
}

///|
/// Child facts are realtime-only: they reach the sink but never a turn ledger,
/// and never any `tool.*` frame a transcript consumer could mistake for a
/// parent tool row.
test "child events never enter the parent transcript or ledger" {
  let hub = EventHub::new()
  let raw : Array[String] = []
  hub.attach(fn(frame) { raw.push(frame) })
  let sink = native_subagent_sink(hub, "session-a", native_ui=true).unwrap()
  let call : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("call-c1"),
    name: @posoco.ToolName::unchecked("bash"),
    arguments: Json::object({ "cmd": Json::string("ls") }),
  }
  sink(native_child_event(@posoco.TurnEvent::ToolCallPending(call)))
  sink(native_child_event(@posoco.TurnEvent::ToolCallStarted(call~)))
  sink(
    native_child_event(
      @posoco.TurnEvent::ToolCallSucceeded(
        call~,
        content="a.txt",
        structured=None,
        attachments=[],
      ),
    ),
  )
  sink(native_child_event(@posoco.TurnEvent::TurnCompleted))
  let frames = native_decode(raw)
  assert_eq(frames.length(), 4)
  let ev_types : Array[String] = []
  for fields in frames {
    assert_eq(native_frame_string(fields, "type"), "subagent.event")
    assert_eq(native_frame_string(fields, "turn_id"), "")
    match fields["ev"] {
      Json::Object(ev) => ev_types.push(native_frame_string(ev, "type"))
      _ => abort("child ev must be an object")
    }
  }
  // No parent frame type appears: a transcript consumer keyed on `tool.*`
  // cannot see a child tool call at all.
  assert_eq(ev_types, [
    "tool.pending", "tool.started", "tool.succeeded", "turn.completed",
  ])
  assert_true(hub.turn_traces.is_empty())
  assert_true(hub.trace.is_empty())
}

///|
/// The opt-in is the only thing that switches the seam on. With the projection
/// off no sink exists, so nothing can be emitted and no question instance is
/// created — the default console wire is untouched.
test "native projection off composes no delegation or question seam" {
  let hub = EventHub::new()
  let raw : Array[String] = []
  hub.attach(fn(frame) { raw.push(frame) })
  assert_true(native_subagent_sink(hub, "session-a", native_ui=false) is None)
  assert_true(native_question_sink(hub, "session-a", native_ui=false) is None)
  assert_true(native_question_tools(hub, "session-a", native_ui=false) is None)
  assert_true(native_subagent_sink(hub, "session-a", native_ui=true) is Some(_))
  assert_true(
    native_question_tools(hub, "session-a", native_ui=true) is Some(_),
  )
  assert_true(raw.is_empty())
}

///|
/// The host may echo any of the forms the question advertised.
test "native question ids match the advertised answer forms" {
  assert_true(native_question_id_matches("question-3", "question-3"))
  assert_true(native_question_id_matches("question-3", "3"))
  assert_true(native_question_id_matches("question-3", "@q3"))
  // The JS host's `question_event` projection spells it `@3`.
  assert_true(native_question_id_matches("question-3", "@3"))
  assert_true(native_question_id_matches("question-3", "@3"))
  assert_true(native_question_id_matches("question-3", " 3 "))
  assert_false(native_question_id_matches("question-3", "4"))
  assert_false(native_question_id_matches("question-3", "@q4"))
  assert_false(native_question_id_matches("question-3", "@4"))
  assert_false(native_question_id_matches("question-3", ""))
}

///|
/// Tool-call fixture for driving the real `notify_user` face.
fn native_notify_ctx(call : @posoco.ToolCall) -> @posoco.ToolCallContext {
  @posoco.ToolCallContext(
    effect_id=@kernel.EffectId::{ value: 0, },
    call_id=call.call_id,
    name=call.name,
    arguments=call.arguments,
    register_cancel=fn(_ : &@posoco.ToolCancellable) { () },
  )
}

///|
/// The non-blocking lifecycle is the *real* extension registry: `notify_user`
/// parks a question, the terminal sees `question.asked` with the answer key,
/// and the existing `ui_response` reply shape settles it through
/// `native_answer_question` — which is exactly what `ConsoleRuntime::resolve_ui`
/// calls in native mode.
async test "native non-blocking question lifecycle is real and answerable" {
  let hub = EventHub::new()
  let raw : Array[String] = []
  hub.attach(fn(frame) { raw.push(frame) })
  let tools = match native_question_tools(hub, "session-a", native_ui=true) {
    Some(tools) => tools
    None => fail("native projection must subscribe the question lifecycle")
  }
  let call : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("call-9"),
    name: @posoco.ToolName::unchecked("notify_user"),
    arguments: Json::object({
      "question": Json::string("Which environment?"),
      "type": Json::string("input"),
    }),
  }
  ignore(@posoco.ToolProvider::execute(tools, native_notify_ctx(call)))
  let asked = native_decode(raw)
  assert_eq(asked.length(), 1)
  let frame = asked[0]
  assert_eq(native_frame_string(frame, "type"), "question.asked")
  assert_eq(native_frame_string(frame, "session_id"), "session-a")
  assert_eq(native_frame_string(frame, "turn_id"), "")
  assert_eq(native_frame_string(frame, "question_id"), "question-1")
  assert_eq(native_frame_string(frame, "short_id"), "@q1")
  assert_eq(native_frame_string(frame, "origin_call"), "call-9")
  assert_eq(native_frame_string(frame, "question"), "Which environment?")
  assert_eq(native_frame_string(frame, "kind"), "input")
  assert_eq(frame["options"], Json::array([]))
  assert_true(hub.trace.is_empty())
  assert_true(hub.turn_traces.is_empty())
  assert_eq(tools.open_questions().length(), 1)
  // A dismissal cannot settle a single question with the current extension
  // API (only an answer or the deadline), so it must not drop it silently.
  assert_false(
    native_answer_question(tools, "question-1", "{\"cancelled\":true}"),
  )
  assert_eq(tools.open_questions().length(), 1)
  // A wrong-kind reply is refused the same way the blocking path refuses it.
  assert_false(native_answer_question(tools, "question-1", "{\"yes\":true}"))
  assert_eq(tools.open_questions().length(), 1)
  // The ui_response shape the native ask panel already sends.
  assert_true(native_answer_question(tools, "@1", "{\"text\":\"staging\"}"))
  assert_eq(tools.open_questions().length(), 0)
  let all = native_decode(raw)
  assert_eq(all.length(), 2)
  let answered = all[1]
  assert_eq(native_frame_string(answered, "type"), "question.answered")
  assert_eq(native_frame_string(answered, "question_id"), "question-1")
  // A repeated answer (and an unknown id) stays a no-op.
  assert_false(
    native_answer_question(tools, "question-1", "{\"text\":\"prod\"}"),
  )
  assert_false(
    native_answer_question(tools, "question-77", "{\"text\":\"prod\"}"),
  )
  assert_eq(native_decode(raw).length(), 2)
}

///|
/// The nested-owner seam: under the projection a session acquires one task
/// scope and releases it on shutdown; with the projection off nothing is
/// acquired. A scope that is never released would hang the host's task group,
/// and a scope that failed to activate must degrade to "no scope" instead of
/// taking the session down.
async test "native session scope activates, retires and degrades" {
  @async.with_task_group(group => {
    let body = async fn(ready : () -> Unit, close : @aqueue.Queue[Unit]) {
      ready()
      ignore(close.get())
    }
    assert_true(
      native_scope_owner(group, native_ui=false, "cetas-native", body) is None,
    )
    let close = match
      native_scope_owner(group, native_ui=true, "cetas-native", body) {
      Some(close) => close
      None => fail("the native projection must own one session task scope")
    }
    // Shutdown path: release the scope so the owner coroutine (and therefore
    // the host group) can drain.
    assert_true(close.try_put(()) catch { _ => false })
    // A real activation failure (already active / closed scope) surfaces here;
    // the owner must report it and hand back no scope instead of wedging.
    let failing = async fn(_ready : () -> Unit, _close : @aqueue.Queue[Unit]) {
      @async.sleep(0)
      raise @posoco.AgentError::Runtime(
        @posoco.RuntimeError::InvocationFailed("task scope is closed"),
      )
    }
    assert_true(
      native_scope_owner(group, native_ui=true, "cetas-native", failing) is None,
    )
  })
}

// ──────────────────────────────────────────────────────────────────────────
// Native delegation composition
// ──────────────────────────────────────────────────────────────────────────

///|
/// Model port that is never called: the composition assertions below only need
/// a slot to route the child through.
priv struct NativeTestModel {}

///|
impl @posoco.ModelPort for NativeTestModel with fn chat(
  _self,
  _scope,
  _messages,
  _tools,
  _options,
  _stream,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse("test model is never called")
}

///|
impl @posoco.ModelPort for NativeTestModel with fn compact(
  _self,
  _scope,
  _messages,
  _tools,
  _options,
  _trigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse("test model is never called")
}

///|
impl @posoco.ModelPort for NativeTestModel with fn provider_config(_self) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig(reasoning_effort_values=[])
}

///|
fn native_test_router() -> @ext_llm.RouterModelPort {
  let port : &@posoco.ModelPort = NativeTestModel::{ }
  let slot = @ext_llm.ModelSlot::ModelSlot(
    id="main",
    label="main",
    provider_id="test",
    model_id="test-model",
    port~,
  )
  @ext_llm.RouterModelPort(slots=[slot]) catch {
    error => abort("test router: " + error.to_string())
  }
}

///|
/// The opted-in native runtime really offers delegation: the composed extension
/// is the subagent tool provider, it publishes `subagent`/`answer_question`/
/// `stop_subagent`, and the child-event sink handed in is the one the extension
/// multicasts through.
async test "native composition provides the real delegation surface" {
  @async.with_task_group(group => {
    let fs : &@workspace.WorkspaceFs = @workspace.NativeWorkspaceFs()
    let hub = EventHub::new()
    let registry = UiRegistry::new()
    let ui_port : &@posoco.UiPort = HubUiPort::new(hub, registry, "session-a")
    let approval : &@permission.ApprovalSource = UiBlockingApprovalSource::new(
      ui_port,
    )
    let received : Array[String] = []
    let ext = compose_native_subagents(
      fs,
      "/tmp/cetas-native-subagent-home",
      "/tmp/cetas-native-subagent-cwd",
      group,
      ui_port,
      approval,
      native_test_router(),
      fn() { @permission.PermissionMode::WorkspaceWrite },
      observers=[fn(event) { received.push(event.child_session) }],
    )
    let manifest = ext.manifest()
    assert_eq(manifest.id, "posoco_ext_subagent")
    let names : Array[String] = []
    for provider in manifest.tools {
      for def in provider.list_tools() {
        names.push(def.name.to_string())
      }
    }
    assert_true(names.contains("subagent"))
    assert_true(names.contains("answer_question"))
    assert_true(names.contains("stop_subagent"))
    // Child composition is the host's: it must not re-expose delegation to the
    // child (depth 1 is structural).
    assert_false(names.contains("agent_swarm"))
    assert_true(received.is_empty())
  })
}
