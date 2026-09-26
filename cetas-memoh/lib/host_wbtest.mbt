///|
/// Host-level ACP contract fixtures. These tests substitute only session
/// assembly; handler routing, Memoh prompt decoding, Router state, AcpBridge
/// streaming, locking and close semantics are production code.

priv struct MemohFakeClient {
  sent : Array[@acp.SessionUpdateParams]
}

///|
fn MemohFakeClient::MemohFakeClient() -> MemohFakeClient {
  { sent: [], }
}

///|
fn memoh_test_client_info(
  name : String,
) -> () -> @acp.ProtocolNullable[@acp.Implementation] {
  fn() {
    Value({
      name,
      title: Value("Memoh contract test"),
      version: "test",
      meta: Omitted,
    })
  }
}

///|
fn memoh_fake_context(
  client : MemohFakeClient,
  client_name? : String = "memoh",
) -> @acp.AgentContext {
  @acp.agent_context(
    request_broker=request => {
      let _ = request
      Err(@acp.AgentContextBrokerFailure(method_name="unused-request"))
    },
    notification_broker=notification => {
      match notification {
        @acp.AgentNotification::SessionUpdate(params) => client.sent.push(params)
        _ => ()
      }
      Ok(())
    },
    client_info=memoh_test_client_info(client_name),
  )
}

///|
fn memoh_test_prompt(text : String) -> Array[@acp.ContentBlock] {
  [
    @acp.ContentBlock::Resource({
      annotations: Omitted,
      resource: @acp.EmbeddedResourceResource::Text({
        mime_type: Value("text/markdown"),
        text: "Bot ID: test-bot\nWorkspace: /workspace",
        uri: @memoh.MEMOH_CURRENT_TURN_URI,
        meta: Omitted,
      }),
      meta: Omitted,
    }),
    @acp.ContentBlock::Text({
      annotations: Omitted,
      text,
      meta: Omitted,
    }),
  ]
}

///|
fn memoh_new_session_params() -> @acp.NewSessionParams {
  {
    cwd: "/workspace",
    additional_directories: Omitted,
    mcp_servers: [],
    meta: Omitted,
  }
}

///|
fn memoh_contract_slot(
  id : String,
  label : String,
  steps : Array[@posoco.ScriptedModelStep],
  efforts? : Array[String] = [],
  context_window? : Int = 128000,
) -> @llm.ModelSlot {
  let base = @llm.ModelSlot::ModelSlot(
    id~,
    label~,
    provider_id="test",
    model_id=id,
    port=@posoco.ScriptedModel(steps),
    thinking_efforts=efforts,
    context_window=Some(context_window),
    default_effort=if efforts.is_empty() { None } else { Some(efforts[0]) },
  )
  if efforts.is_empty() {
    base
  } else {
    { ..base, rebuild_on_effort: Some(_ => base), }
  }
}

///|
fn memoh_contract_session(
  slots : Array[@llm.ModelSlot],
) -> MemohSession raise @posoco.CompositionError {
  let router = @llm.RouterModelPort(slots~)
  let memoh = @memoh.Memoh()
  let bridge = @ext_acp.AcpBridge(context_window=router_context_window(router))
  let exts : Array[&@posoco.Extension] = [
    router as &@posoco.Extension,
    memoh as &@posoco.Extension,
    bridge as &@posoco.Extension,
  ]
  let agent = @posoco.Agent(
    exts~,
    config=@posoco.agent_config(
      temperature=Some(0.0),
      system_prompt=Some("contract test"),
    ),
  )
  {
    bridge,
    memoh,
    router,
    agent,
    in_flight: None,
    turn_lock: @async.Mutex::Mutex(),
  }
}

///|
fn MemohHost::of(
  spawn_session~ : async (@acp.NewSessionParams) -> Result[
    MemohSession,
    String,
  ],
) -> MemohHost {
  {
    version: "test",
    spawn_session,
    sessions: Map::from_array([]),
  }
}

///|
fn memoh_contract_host(
  slots : Array[@llm.ModelSlot],
) -> MemohHost {
  let spawn_session = async fn(
    _params : @acp.NewSessionParams,
  ) -> Result[MemohSession, String] {
    Ok(memoh_contract_session(slots)) catch {
      error => Err(error.to_string())
    }
  }
  MemohHost::of(spawn_session~)
}

///|
async test "Memoh host rejects a non-Memoh ACP client before session assembly" {
  let host = memoh_contract_host([
    memoh_contract_slot("test/a", "A", []),
  ])
  let result : Result[@acp.NewSessionResult, @acp.HandlerError] = Ok(
    host.handle_new_session(
      memoh_fake_context(MemohFakeClient(), client_name="zed"),
      memoh_new_session_params(),
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(@acp.HandlerError::InvalidParams(message~)) =>
      assert_true(message.contains("invalid Memoh client"))
    _ => fail("expected invalid Memoh client rejection")
  }
}

///|
async test "Memoh new session advertises authoritative model options" {
  let host = memoh_contract_host([
    memoh_contract_slot("test/a", "A", [], efforts=["low", "high"]),
    memoh_contract_slot("test/b", "B", []),
  ])
  let result = host.handle_new_session(
    memoh_fake_context(MemohFakeClient()),
    memoh_new_session_params(),
  )
  guard result.config_options is Value(options) else {
    fail("expected config options")
  }
  assert_eq(options.length(), 2)
  assert_eq(options[0].id, "model")
  assert_eq(options[1].id, "effort")
}

///|
async test "Memoh prompt streams through the ACP bridge" {
  let host = memoh_contract_host([
    memoh_contract_slot(
      "test/a",
      "A",
      [@posoco.Respond(@posoco.tk_stop_response("hello from Cetas"))],
    ),
  ])
  let client = MemohFakeClient()
  let context = memoh_fake_context(client)
  let created = host.handle_new_session(context, memoh_new_session_params())
  let result = host.handle_prompt(context, {
    session_id: created.session_id,
    prompt: memoh_test_prompt("hello"),
    meta: Omitted,
  })
  assert_true(result.stop_reason is @acp.StopReason::EndTurn)
  let mut saw_text = false
  for frame in client.sent {
    match frame.update {
      @acp.SessionUpdate::AgentMessageChunk(chunk) =>
        match chunk.content {
          @acp.ContentBlock::Text(text) =>
            if text.text.contains("hello from Cetas") {
              saw_text = true
            }
          _ => ()
        }
      _ => ()
    }
  }
  assert_true(saw_text)
}

///|
async test "Memoh config switch returns and pushes the full snapshot" {
  let host = memoh_contract_host([
    memoh_contract_slot("test/a", "A", []),
    memoh_contract_slot("test/b", "B", [], context_window=1000000),
  ])
  let client = MemohFakeClient()
  let context = memoh_fake_context(client)
  let created = host.handle_new_session(context, memoh_new_session_params())
  let result = host.handle_set_config_option(context, {
    session_id: created.session_id,
    config_id: "model",
    value: @acp.SessionConfigValue::ValueId("test/b"),
    meta: Omitted,
  })
  assert_eq(result.config_options.length(), 1)
  match result.config_options[0].kind {
    @acp.SessionConfigOptionKind::Select(select) =>
      assert_eq(select.current_value, "test/b")
    _ => fail("expected model select option")
  }

  let mut saw_update = false
  for frame in client.sent {
    match frame.update {
      @acp.SessionUpdate::ConfigOptionUpdate(update) => {
        saw_update = true
        assert_eq(update.config_options.length(), 1)
      }
      _ => ()
    }
  }
  assert_true(saw_update)
}

///|
async test "Memoh close retires the session and rejects later prompts" {
  let host = memoh_contract_host([
    memoh_contract_slot(
      "test/a",
      "A",
      [@posoco.Respond(@posoco.tk_stop_response("unused"))],
    ),
  ])
  let client = MemohFakeClient()
  let context = memoh_fake_context(client)
  let created = host.handle_new_session(context, memoh_new_session_params())
  ignore(host.handle_close(context, {
    session_id: created.session_id,
    meta: Omitted,
  }))

  let result : Result[@acp.PromptResult, @acp.HandlerError] = Ok(
    host.handle_prompt(context, {
      session_id: created.session_id,
      prompt: memoh_test_prompt("after close"),
      meta: Omitted,
    }),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(@acp.HandlerError::InvalidParams(message~)) =>
      assert_true(message.contains("unknown session"))
    _ => fail("retired Memoh session must reject prompts")
  }
}
