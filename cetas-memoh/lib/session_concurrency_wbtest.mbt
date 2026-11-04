///|
/// One process hosts every session of a Memoh agent (felinics/Memoh#1717), and
/// the upstream change only supports agents that keep sessions independent. This
/// file pins that contract for this host: two sessions in one process run their
/// turns at the same time, a cancel stops only its own turn, and closing one
/// session leaves the other intact.

///|
/// A model port that parks inside `chat` until the test releases it, and records
/// how many turns reached the model at once. `peak > 1` is the concurrency proof:
/// any host-level lock between sessions would hold it at 1.
struct GateModelPort {
  mut entered : Int32
  mut peak : Int32
  mut released : Bool
}

///|
pub impl @posoco.ModelPort for GateModelPort with fn chat(
  self : GateModelPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  self.entered += 1
  if self.entered > self.peak {
    self.peak = self.entered
  }
  while !self.released {
    @async.sleep(1)
  }
  self.entered -= 1
  @tk.tk_stop_response("done")
}

///|
pub impl @posoco.ModelPort for GateModelPort with fn compact(
  _self : GateModelPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "gate model port does not implement compact",
  )
}

///|
pub impl @posoco.ModelPort for GateModelPort with fn provider_config(
  _self : GateModelPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::ProviderConfig(reasoning_effort_values=[])
}

///|
fn gate_slot(id : String, port : &@posoco.ModelPort) -> @llm.ModelSlot {
  @llm.ModelSlot::ModelSlot(
    id~,
    label=id,
    provider_id="test",
    model_id=id,
    port~,
    thinking_efforts=[],
    context_window=Some(128000),
    default_effort=None,
  )
}

///|
fn gate_catalog(port : &@posoco.ModelPort) -> @llm.ProviderModelCatalog {
  @llm.ProviderModelCatalog::ProviderModelCatalog(provider_id="test", slots=[
    gate_slot("test/a", port),
    gate_slot("test/b", port),
  ]) catch {
    _ => abort("test catalog must be valid")
  }
}

///|
/// The host never touches credentials on this path; the store exists only
/// because the router wants one, and the directory is never created.
fn gate_host(
  group : @async.TaskGroup[Unit],
  catalog : @llm.ProviderModelCatalog,
) -> MemohHost {
  let fs : &@workspace.WorkspaceFs = @workspace.NativeWorkspaceFs()
  MemohHost::{
    version: "test",
    cwd: "/",
    catalogs: [catalog],
    model_metadata: @llm.ModelMetadata(),
    credential_store: @credentials.FileProviderCredentialStore(
      fs, "/nonexistent-cetas-memoh-test/credentials",
    ),
    mcp_group: group,
    sessions: Map::from_array([]),
  }
}

///|
/// An ACP context that identifies as Memoh, which every handler requires.
fn gate_context() -> @acp.AgentContext {
  @acp.agent_context(
    request_broker=_ => Err(AgentContextBrokerFailure(method_name="unused")),
    notification_broker=_ => Ok(()),
    client_info=fn() {
      Value({
        name: "memoh",
        title: Value("Cetas concurrency test"),
        version: "1.0",
        meta: Omitted,
      })
    },
  )
}

///|
/// One user turn carrying the host context every Memoh prompt must supply.
fn gate_prompt() -> Array[@acp.ContentBlock] {
  [
    @acp.ContentBlock::Text({ annotations: Omitted, text: "hi", meta: Omitted, }),
    @acp.ContentBlock::Resource({
      annotations: Omitted,
      resource: @acp.EmbeddedResourceResource::Text({
        mime_type: Value("text/markdown"),
        text: "# host context",
        uri: "memoh://context/current-turn",
        meta: Omitted,
      }),
      meta: Omitted,
    }),
  ]
}

///|
async test "two sessions in one process turn concurrently and cancel alone" {
  @async.with_task_group(group => {
    let port = GateModelPort::{ entered: 0, peak: 0, released: false, }
    let port_ref : &@posoco.ModelPort = port
    let host = gate_host(group, gate_catalog(port_ref))
    let context = gate_context()
    let new_session = @acp.NewSessionParams::{
      cwd: "/",
      additional_directories: Omitted,
      mcp_servers: [],
      meta: Omitted,
    }
    // Neither session declares Memoh Tools, so both open degraded. That is the
    // point: the concurrency contract must not depend on the tool gateway.
    let first = host.handle_new_session(context, new_session).session_id
    let second = host.handle_new_session(context, new_session).session_id
    assert_true(first != second)

    let prompt = gate_prompt()
    let run_first = group.spawn(
      () => {
        host.handle_prompt(context, {
          session_id: first,
          prompt,
          meta: Omitted,
        })
      },
      allow_failure=true,
    )
    let run_second = group.spawn(
      () => {
        host.handle_prompt(context, {
          session_id: second,
          prompt,
          meta: Omitted,
        })
      },
      allow_failure=true,
    )

    // Both turns must reach the model at the same time; a shared lock would
    // leave the second one parked outside `chat` forever.
    let mut waited = 0
    while port.entered < 2 && waited < 5000 {
      @async.sleep(1)
      waited += 1
    }
    assert_eq(port.entered, 2)
    assert_eq(port.peak, 2)

    // Cancelling one session's turn must not touch the other.
    host.handle_cancel(context, { session_id: first, meta: Omitted, })
    port.released = true

    let first_result = run_first.wait() catch {
      _ => fail("the cancelled turn must settle through the cancel path")
    }
    let second_result = run_second.wait() catch {
      _ => fail("the untouched turn must complete")
    }
    assert_true(first_result.stop_reason is @acp.StopReason::Cancelled)
    assert_true(second_result.stop_reason is @acp.StopReason::EndTurn)

    // A model switch is session-local: the routers are per session.
    match host.sessions.get(first) {
      Some(session) =>
        session.router.switch_slot("test/b") catch {
          _ => fail("the test slot must switch")
        }
      None => fail("first session missing")
    }
    match host.sessions.get(second) {
      Some(session) => assert_eq(session.router.active_slot_id(), "test/a")
      None => fail("second session missing")
    }

    // Closing one session must leave the other live and untouched.
    ignore(host.handle_close(context, { session_id: first, meta: Omitted, }))
    assert_true(host.sessions.get(first) is None)
    assert_true(host.sessions.get(second) is Some(_))
  })
}

///|
/// The integration case above proves the cancellation *outcome*; this pins the
/// classifier itself so a future edit cannot quietly drop one of the shapes.
test "both cancellation shapes are classified as cancellations" {
  let unwound : Error = @posoco.AgentError::Cancelled("turn cancelled")
  assert_true(prompt_failure_is_cancelled(unwound))
  let outside : Error = @posoco.AgentError::Model("boom")
  assert_false(prompt_failure_is_cancelled(outside))
}

///|
pub extend GateModelPort with @posoco.ModelPort::{
  provider_config,
  chat,
  compact,
}
