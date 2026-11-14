///|
/// Native terminal UI projection is an explicit host-config opt-in. Nothing in
/// the shared console path may turn it on implicitly, because the same frames
/// feed every other console consumer.
test "console config keeps the native UI projection opt-in" {
  let fs_impl = @workspace.NativeWorkspaceFs()
  let fs : &@workspace.WorkspaceFs = fs_impl
  let shared = console_config(
    fs, "/tmp/cetas-go-ui", "cetas-web", "cetas-web/0.1",
  )
  assert_false(shared.native_ui)
  let native = console_config(
    fs,
    "/tmp/cetas-go-ui",
    "cetas-go",
    "cetas-go/0.1",
    native_ui=true,
  )
  assert_true(native.native_ui)
}

///|
/// Call fixture: one call id that every lifecycle assertion below must keep.
fn console_test_call(name : String, call_id : String) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked(call_id),
    name: @posoco.ToolName::unchecked(name),
    arguments: Json::object({ "cmd": Json::string("ls -la") }),
  }
}

///|
/// Drive one observer and return exactly what reached the attached sink.
///
/// The sink is the realtime seam: a frame missing here is not deliverable
/// without polling the trace ledger, which the native host must never do.
fn console_sink_frames(
  events : Array[@posoco.TurnEvent],
  native_ui~ : Bool,
  scope~ : @posoco.EventScope? = None,
) -> Array[Map[String, Json]] {
  let hub = EventHub::new()
  let frames : Array[String] = []
  hub.attach(fn(frame) { frames.push(frame) })
  let observer = ConsoleObserver::new(
    hub,
    (None : @posoco.Events?),
    "session-a",
    "cetas-go/0.1",
    native_ui~,
  )
  observer.begin_turn("t-1")
  for event in events {
    @posoco.Observer::on_event(observer, scope, event)
  }
  frames.map(frame => {
    let parsed = @json.parse(frame) catch {
      _ => abort("console frame must be a JSON object")
    }
    match parsed {
      Json::Object(fields) => fields
      _ => abort("console frame must be a JSON object")
    }
  })
}

///|
fn console_frame_string(fields : Map[String, Json], key : String) -> String {
  match fields.get(key) {
    Some(Json::String(value)) => value
    _ => ""
  }
}

///|
fn console_frame_types(frames : Array[Map[String, Json]]) -> Array[String] {
  frames.map(fields => console_frame_string(fields, "type"))
}

///|
/// The shared web wire contract stays byte-for-byte: same event names, same
/// flat tool fields, no lifecycle phase and no ledger-only broadcasts.
test "default console protocol keeps the legacy tool lifecycle wire shape" {
  let call = console_test_call("bash", "call-1")
  let events : Array[@posoco.TurnEvent] = [
    @posoco.TurnEvent::ToolCallPending(call),
    @posoco.TurnEvent::ToolCallApproved(call~, consent_scope=Some("once")),
    @posoco.TurnEvent::ToolCallStarted(call~),
    @posoco.TurnEvent::ToolCallSucceeded(
      call~,
      content="ok",
      structured=Some({ "summary": Json::string("ok") }),
      attachments=[@posoco.Content::Image(media_type="image/png", data="aW8=")],
    ),
    @posoco.TurnEvent::ToolCallFailed(
      call~,
      failure=Runtime(category="adapter", message="io broke"),
    ),
    @posoco.TurnEvent::ToolCallRejected(call~, reason=UnknownTool),
    @posoco.TurnEvent::ToolCallAbandoned(call~, reason="run ended mid-wave"),
    @posoco.TurnEvent::StreamChunkReceived(
      chunk=@posoco.StreamChunk::ToolCallDelta(
        index=0,
        id=Some("call-1"),
        name=Some("bash"),
        arguments_delta=Some("{\"cmd\":"),
      ),
    ),
    @posoco.TurnEvent::StreamChunksDropped(count=3),
    @posoco.TurnEvent::ConfigChanged(
      field="model",
      old_value="a",
      new_value="b",
    ),
    @posoco.TurnEvent::OperationFinalized(
      operation="compact",
      outcome="completed",
      detail="",
    ),
    @posoco.TurnEvent::Custom(
      source="posoco_ext_subagent",
      label="spawned",
      data=Json::object({ "child_session": Json::string("subagent-1") }),
    ),
  ]
  let frames = console_sink_frames(events, native_ui=false)
  assert_eq(console_frame_types(frames), [
    "tool.started", "tool.approved", "tool.completed", "tool.completed", "tool.completed",
    "tool.completed",
  ])
  for fields in frames {
    assert_true(fields.get("phase") is None)
    assert_true(fields.get("render") is None)
  }
  let started = frames[0]
  assert_eq(started["session_id"], Json::string("session-a"))
  assert_eq(started["turn_id"], Json::string("t-1"))
  assert_eq(started["tool_call_id"], Json::string("call-1"))
  assert_eq(
    started["arguments"],
    Json::object({ "cmd": Json::string("ls -la") }),
  )
  assert_eq(frames[1]["consent_scope"], Json::string("once"))
  let succeeded = frames[2]
  assert_eq(succeeded["is_error"], Json::boolean(false))
  assert_true(succeeded.get("structured") is None)
  assert_true(succeeded.get("attachments") is None)
  assert_eq(frames[4]["result"], Json::string("UnknownTool"))
  assert_eq(frames[5]["result"], Json::string("run ended mid-wave"))
}

///|
/// Native opt-in: one distinct phase per tool lifecycle node instead of four
/// terminal states collapsing onto an `is_error` flag.
test "native UI projection separates every tool lifecycle phase" {
  let call = console_test_call("bash", "call-1")
  let events : Array[@posoco.TurnEvent] = [
    @posoco.TurnEvent::ToolCallPending(call),
    @posoco.TurnEvent::ToolCallApproved(call~, consent_scope=None),
    @posoco.TurnEvent::ToolCallStarted(call~),
    @posoco.TurnEvent::ToolCallSucceeded(
      call~,
      content="file body",
      structured=Some({ "summary": Json::string("read ok") }),
      attachments=[@posoco.Content::Image(media_type="image/png", data="aW8=")],
    ),
    @posoco.TurnEvent::ToolCallFailed(
      call~,
      failure=Runtime(category="adapter", message="io broke"),
    ),
    @posoco.TurnEvent::ToolCallFailed(
      call~,
      failure=ReportedError(content="exit 1", structured=None),
    ),
    @posoco.TurnEvent::ToolCallRejected(call~, reason=NotOffered),
    @posoco.TurnEvent::ToolCallAbandoned(call~, reason="run ended mid-wave"),
  ]
  let frames = console_sink_frames(events, native_ui=true)
  assert_eq(console_frame_types(frames), [
    "tool.started", "tool.approved", "tool.started_run", "tool.completed", "tool.completed",
    "tool.completed", "tool.completed", "tool.completed",
  ])
  assert_eq(frames[0]["phase"], Json::string("pending"))
  assert_eq(frames[1]["phase"], Json::string("approved"))
  assert_eq(frames[2]["phase"], Json::string("started"))
  assert_eq(frames[2]["tool_name"], Json::string("bash"))
  assert_eq(
    frames[2]["arguments"],
    Json::object({ "cmd": Json::string("ls -la") }),
  )
  for fields in frames {
    assert_eq(fields["tool_call_id"], Json::string("call-1"))
    assert_eq(fields["session_id"], Json::string("session-a"))
    assert_eq(fields["turn_id"], Json::string("t-1"))
  }
  let succeeded = frames[3]
  assert_eq(succeeded["phase"], Json::string("succeeded"))
  assert_eq(succeeded["result"], Json::string("file body"))
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
  let runtime_failed = frames[4]
  assert_eq(runtime_failed["phase"], Json::string("failed"))
  assert_eq(runtime_failed["failure_kind"], Json::string("runtime"))
  assert_eq(runtime_failed["error_category"], Json::string("adapter"))
  assert_eq(runtime_failed["structured"], Json::null())
  let reported_failed = frames[5]
  assert_eq(reported_failed["phase"], Json::string("failed"))
  assert_eq(reported_failed["failure_kind"], Json::string("reported_error"))
  assert_eq(reported_failed["error_category"], Json::string(""))
  assert_eq(reported_failed["result"], Json::string("exit 1"))
  let rejected = frames[6]
  assert_eq(rejected["phase"], Json::string("rejected"))
  assert_eq(rejected["reason"], Json::string("NotOffered"))
  assert_true(rejected["is_error"] is Json::True)
  assert_eq(frames[7]["phase"], Json::string("abandoned"))
  assert_eq(frames[7]["reason"], Json::string("run ended mid-wave"))
}

///|
/// Streamed tool-call argument fragments are the only way a terminal can show
/// arguments before the authoritative call lands.
test "native UI projection streams tool argument deltas" {
  let events : Array[@posoco.TurnEvent] = [
    @posoco.TurnEvent::StreamChunkReceived(
      chunk=@posoco.StreamChunk::ToolCallDelta(
        index=0,
        id=Some("call-1"),
        name=Some("bash"),
        arguments_delta=Some("{\"cmd\":"),
      ),
    ),
    @posoco.TurnEvent::StreamChunkReceived(
      chunk=@posoco.StreamChunk::ToolCallDelta(
        index=0,
        id=None,
        name=None,
        arguments_delta=Some("\"ls\"}"),
      ),
    ),
  ]
  let frames = console_sink_frames(events, native_ui=true)
  assert_eq(console_frame_types(frames), ["tool.args_delta", "tool.args_delta"])
  assert_eq(frames[0]["index"], Json::number(0.0))
  assert_eq(frames[0]["id"], Json::string("call-1"))
  assert_eq(frames[0]["name"], Json::string("bash"))
  assert_eq(frames[0]["delta"], Json::string("{\"cmd\":"))
  assert_eq(frames[1]["id"], Json::null())
  assert_eq(frames[1]["name"], Json::null())
  assert_eq(frames[1]["delta"], Json::string("\"ls\"}"))
  // Default consumers never see argument fragments.
  assert_true(console_sink_frames(events, native_ui=false).is_empty())
}

///|
/// Extension `Custom` facts carry their source, the event scope and the
/// subagent attribution the terminal needs to place a child row.
test "custom events keep source and subagent attribution only when opted in" {
  let scope : @posoco.EventScope = {
    session_id: @posoco.SessionId::unchecked("scope-session"),
    run_id: @posoco.RunId::unchecked("run-1"),
    turn_id: @posoco.TurnId::unchecked("turn-9"),
  }
  let events : Array[@posoco.TurnEvent] = [
    @posoco.TurnEvent::Custom(
      source="posoco_ext_subagent",
      label="spawned",
      data=Json::object({
        "child_session": Json::string("subagent-1"),
        "parent_call": Json::string("call-9"),
        "kind": Json::string("explore"),
      }),
    ),
  ]
  let hidden = console_sink_frames(events, native_ui=false, scope=Some(scope))
  assert_true(hidden.is_empty())
  let frames = console_sink_frames(events, native_ui=true, scope=Some(scope))
  assert_eq(console_frame_types(frames), ["custom"])
  let custom = frames[0]
  assert_eq(custom["source"], Json::string("posoco_ext_subagent"))
  assert_eq(custom["label"], Json::string("spawned"))
  assert_eq(custom["child_session"], Json::string("subagent-1"))
  assert_eq(custom["parent_call"], Json::string("call-9"))
  assert_eq(
    custom["scope"],
    Json::object(
      Map::from_array([
        ("session_id", Json::string("scope-session")),
        ("run_id", Json::string("run-1")),
        ("turn_id", Json::string("turn-9")),
      ]),
    ),
  )
  // Unscoped facts stay explicit instead of inventing console attribution.
  let unscoped = console_sink_frames(events, native_ui=true)
  assert_eq(unscoped[0]["scope"], Json::null())
  assert_eq(unscoped[0]["parent_call"], Json::string("call-9"))
}

///|
/// Config, operation-finalization and chunk-backpressure facts are ledger-only
/// for the web host but renderable on the native status bar/dashboard.
test "config operation and dropped-chunk facts reach the native sink" {
  let events : Array[@posoco.TurnEvent] = [
    @posoco.TurnEvent::StreamChunksDropped(count=3),
    @posoco.TurnEvent::ConfigWarning(
      field="effort",
      value="turbo",
      reason="unsupported",
    ),
    @posoco.TurnEvent::ConfigChanged(
      field="model",
      old_value="a",
      new_value="b",
    ),
    @posoco.TurnEvent::OperationFinalized(
      operation="compact",
      outcome="completed",
      detail="",
    ),
  ]
  assert_true(console_sink_frames(events, native_ui=false).is_empty())
  let frames = console_sink_frames(events, native_ui=true)
  assert_eq(console_frame_types(frames), [
    "stream.dropped", "config.warning", "config.changed", "operation.finalized",
  ])
  assert_eq(frames[0]["count"], Json::number(3.0))
  assert_eq(frames[1]["field"], Json::string("effort"))
  assert_eq(frames[1]["value"], Json::string("turbo"))
  assert_eq(frames[1]["reason"], Json::string("unsupported"))
  assert_eq(frames[2]["old_value"], Json::string("a"))
  assert_eq(frames[2]["new_value"], Json::string("b"))
  assert_eq(frames[3]["operation"], Json::string("compact"))
  assert_eq(frames[3]["outcome"], Json::string("completed"))
  assert_eq(frames[3]["detail"], Json::string(""))
}

///|
/// Render shape for the terminal: a native frame adds one `render` object that
/// keeps the slot tag, key, body type/payload and ttl. The legacy flat fields
/// stay on the frame untouched.
test "native UiPort keeps the unflattened UiRender shape" {
  let hub = EventHub::new()
  let frames : Array[String] = []
  hub.attach(fn(frame) { frames.push(frame) })
  let registry = UiRegistry::new()
  let port = HubUiPort::new(hub, registry, "session-a", native_ui=true)
  @posoco.UiPort::render(port, @posoco.UiRender::{
    slot: @posoco.UiSlot::Status,
    key: "goal.progress",
    title: Some("Goal"),
    body: @posoco.UiBody::Progress(0.5),
    ttl_ms: Some(1500),
  })
  @posoco.UiPort::render(port, @posoco.UiRender::{
    slot: @posoco.UiSlot::Notice,
    key: "oauth",
    title: None,
    body: @posoco.UiBody::Markdown("**hello**"),
    ttl_ms: None,
  })
  @posoco.UiPort::render(port, @posoco.UiRender::{
    slot: @posoco.UiSlot::Widget,
    key: "board",
    title: None,
    body: @posoco.UiBody::KeyValue([("open", "2")]),
    ttl_ms: None,
  })
  let decoded = frames.map(frame => {
    let parsed = @json.parse(frame) catch {
      _ => abort("ui.render frame must be an object")
    }
    match parsed {
      Json::Object(fields) => fields
      _ => abort("ui.render frame must be an object")
    }
  })
  assert_eq(console_frame_types(decoded), [
    "ui.render", "ui.render", "ui.render",
  ])
  // Legacy flat fields are preserved for every existing consumer.
  assert_eq(decoded[0]["key"], Json::string("goal.progress"))
  assert_eq(decoded[0]["text"], Json::null())
  let progress = match decoded[0]["render"] {
    Json::Object(render) => render
    _ => abort("native ui.render must carry a render object")
  }
  assert_eq(progress["slot"], Json::string("status"))
  assert_eq(progress["key"], Json::string("goal.progress"))
  assert_eq(progress["title"], Json::string("Goal"))
  assert_eq(progress["ttl_ms"], Json::number(1500.0))
  assert_eq(
    progress["body"],
    Json::object(
      Map::from_array([
        ("type", Json::string("progress")),
        ("current", Json::number(0.5)),
      ]),
    ),
  )
  let markdown = match decoded[1]["render"] {
    Json::Object(render) => render
    _ => abort("native ui.render must carry a render object")
  }
  assert_eq(markdown["title"], Json::null())
  assert_eq(markdown["ttl_ms"], Json::null())
  assert_eq(
    markdown["body"],
    Json::object(
      Map::from_array([
        ("type", Json::string("markdown")),
        ("text", Json::string("**hello**")),
      ]),
    ),
  )
  let key_value = match decoded[2]["render"] {
    Json::Object(render) => render
    _ => abort("native ui.render must carry a render object")
  }
  assert_eq(
    key_value["body"],
    Json::object(
      Map::from_array([
        ("type", Json::string("key_value")),
        (
          "entries",
          Json::array([
            Json::object(
              Map::from_array([
                ("key", Json::string("open")),
                ("value", Json::string("2")),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  )
}

///|
/// The default web frame keeps exactly the flattened shape it always had.
test "default UiPort render stays flattened" {
  let hub = EventHub::new()
  let frames : Array[String] = []
  hub.attach(fn(frame) { frames.push(frame) })
  let registry = UiRegistry::new()
  let port = HubUiPort::new(hub, registry, "session-a")
  @posoco.UiPort::render(port, @posoco.UiRender::{
    slot: @posoco.UiSlot::Status,
    key: "goal.progress",
    title: Some("Goal"),
    body: @posoco.UiBody::Progress(0.5),
    ttl_ms: Some(1500),
  })
  let fields = match @json.parse(frames[0]) {
    Json::Object(fields) => fields
    _ => fail("ui.render frame must be an object")
  }
  assert_eq(fields["key"], Json::string("goal.progress"))
  assert_eq(fields["slot"], Json::string("Status"))
  assert_true(fields.get("render") is None)
}

///|
/// A host reply that cannot be decoded fails closed and, natively, leaves a
/// traceable diagnostic. The diagnostic is a bounded reason label: the reply
/// itself never reaches the event hub, so a malformed secret answer cannot
/// leak.
async test "native UiPort reports decode failures without echoing the reply" {
  @async.with_task_group(group => {
    let hub = EventHub::new()
    let frames : Array[String] = []
    hub.attach(fn(frame) { frames.push(frame) })
    let registry = UiRegistry::new()
    let port = HubUiPort::new_secret(hub, registry, "session-a", native_ui=true)
    let answer = group.spawn(() => {
      @posoco.UiPort::request(
        port,
        @posoco.UiRequest::Input(
          prompt="API key",
          default=Some("sk-default-must-not-leak"),
        ),
      )
    })
    @async.sleep(10)
    assert_false(frames.join("\n").contains("sk-default-must-not-leak"))
    registry.resolve("u-1", "{\"text\":\"sk-live")
    assert_true(answer.wait() is @posoco.UiResponse::Cancelled)
    let joined = frames.join("\n")
    assert_true(joined.contains("ui.response_error"))
    assert_true(joined.contains("invalid_json"))
    assert_false(joined.contains("sk-live"))
  })
}

///|
/// Default consumers keep the silent fail-closed answer they always had: no
/// new frame appears on their wire.
async test "default UiPort decode failures stay unobservable" {
  @async.with_task_group(group => {
    let hub = EventHub::new()
    let frames : Array[String] = []
    hub.attach(fn(frame) { frames.push(frame) })
    let registry = UiRegistry::new()
    let port = HubUiPort::new(hub, registry, "session-a")
    let answer = group.spawn(() => {
      @posoco.UiPort::request(
        port,
        @posoco.UiRequest::Confirm(prompt="Proceed?"),
      )
    })
    @async.sleep(10)
    registry.resolve("u-1", "{\"yes\":\"maybe\"}")
    assert_true(answer.wait() is @posoco.UiResponse::Cancelled)
    assert_false(frames.join("\n").contains("ui.response_error"))
  })
}
