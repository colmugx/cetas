///|
/// One live Memoh ACP session. Every session owns a Router, Memoh adapter,
/// ACP projection bridge and MCP connection; no durable conversation state is
/// stored here.
priv struct MemohSession {
  bridge : @ext_acp.AcpBridge
  memoh : @memoh.Memoh
  router : @llm.RouterModelPort
  agent : @posoco.Agent
  mut in_flight : @async.Task[@posoco.TurnResult]?
  turn_lock : @async.Mutex
}

///|
priv struct SessionIdState {
  mut last_ms : Int64
  mut seq : Int
}

///|
let session_id_state : SessionIdState = { last_ms: 0L, seq: 0, }

///|
fn mint_memoh_session_id() -> String {
  let now = @async.now()
  if now > session_id_state.last_ms {
    session_id_state.last_ms = now
    session_id_state.seq = 0
    "cetas-memoh-\{now}"
  } else {
    session_id_state.seq += 1
    "cetas-memoh-\{now}-\{session_id_state.seq}"
  }
}

///|
fn router_context_window(router : @llm.RouterModelPort) -> Int? {
  let active = router.active_slot_id()
  for slot in router.list_slots() {
    if slot.id == active {
      return slot.context_window
    }
  }
  None
}

///|
fn memoh_system_prompt() -> String {
  "You are Cetas running as a first-class Memoh agent runtime. " +
  "Memoh is the authority for conversation continuity, workspace/platform " +
  "operations, memory, and host authorization. Current-turn Memoh context " +
  "is supplied separately from the user's message. Use Memoh Tools for " +
  "platform and workspace actions; do not invent a parallel host state."
}

///|
pub struct MemohHost {
  version : String
  priv spawn_session : async (@acp.NewSessionParams) -> Result[
    MemohSession,
    String,
  ]
  priv sessions : Map[String, MemohSession]
}

///|
pub async fn MemohHost::MemohHost(
  home~ : String,
  cwd~ : String,
  mcp_group~ : @async.TaskGroup[Unit],
  version? : String = "0.1.0",
) -> MemohHost raise @posoco.CompositionError {
  let fs = @workspace.NativeWorkspaceFs()
  let platform = build_provider_platform(fs, home)
  for issue in platform.issues {
    memoh_warn(
      "cetas-memoh: provider " +
      issue.provider_id +
      " skipped: " +
      issue.detail +
      "\n",
    )
  }
  let _ = cwd
  let catalogs = platform.catalogs
  let credential_store = platform.credential_store
  let spawn_session = async fn(
    params : @acp.NewSessionParams,
  ) -> Result[MemohSession, String] {
    build_memoh_session(catalogs, credential_store, mcp_group, params)
  }
  {
    version,
    spawn_session,
    sessions: Map::from_array([]),
  }
}

///|
fn MemohHost::require_session(
  self : MemohHost,
  session_id : String,
) -> MemohSession raise @acp.HandlerError {
  match self.sessions.get(session_id) {
    Some(session) => session
    None =>
      raise @acp.HandlerError::InvalidParams(
        message="cetas-memoh: unknown session '" + session_id + "'",
      )
  }
}

///|
/// Convert typed host-contract failures to concise, non-secret diagnostics.
fn memoh_error_detail(error : @memoh.MemohError) -> String {
  match error {
    @memoh.MemohError::InvalidClient(reason~) =>
      "invalid Memoh client: " + reason
    @memoh.MemohError::MissingContext => "missing Memoh current-turn context"
    @memoh.MemohError::InvalidContext(reason~) =>
      "invalid Memoh context: " + reason
    @memoh.MemohError::UnsupportedPromptBlock(kind~) =>
      "unsupported Memoh prompt block: " + kind
    @memoh.MemohError::MissingToolGateway => "missing Memoh Tools gateway"
    @memoh.MemohError::InvalidMcpServer(reason~) =>
      "invalid Memoh Tools declaration: " + reason
    @memoh.MemohError::UnsupportedMcpTransport(transport~) =>
      "unsupported Memoh Tools transport: " + transport
  }
}

///|
async fn build_memoh_session(
  catalogs : Array[@llm.ProviderModelCatalog],
  credential_store : @credentials.FileProviderCredentialStore,
  mcp_group : @async.TaskGroup[Unit],
  params : @acp.NewSessionParams,
) -> Result[MemohSession, String] noraise {
  let router = @llm.RouterModelPort::from_catalogs(
    catalogs,
    provider_credential_store=Some(credential_store),
  ) catch {
    error => return Err("model router composition failed: " + error.to_string())
  }
  let memoh = @memoh.Memoh()
  let bridge = @ext_acp.AcpBridge(context_window=router_context_window(router))
  let gateway = @memoh.memoh_tools_mcp_config(Value(params.mcp_servers)) catch {
    error =>
      return Err("Memoh Tools contract failed: " + memoh_error_detail(error))
  }
  let mcp_bridge = @mcp.MCPToolBridge()
  let connect_result = mcp_bridge.connect(gateway, mcp_group) catch {
    error =>
      return Err(
        "Memoh Tools connection failed before handshake completed: " +
        error.to_string(),
      )
  }
  match connect_result {
    Ok(_) => ()
    Err(message) => return Err("Memoh Tools connection failed: " + message)
  }
  let exts : Array[&@posoco.Extension] = [
    router as &@posoco.Extension,
    memoh as &@posoco.Extension,
    bridge as &@posoco.Extension,
    mcp_bridge as &@posoco.Extension,
  ]
  let config = @posoco.agent_config(
    temperature=Some(0.0),
    system_prompt=Some(memoh_system_prompt()),
  )
  let agent = @posoco.Agent(exts~, config~) catch {
    error => return Err("agent composition failed: " + error.to_string())
  }
  Ok({
    bridge,
    memoh,
    router,
    agent,
    in_flight: None,
    turn_lock: @async.Mutex::Mutex(),
  })
}

///|
pub fn MemohHost::agent_spec(
  self : MemohHost,
) -> Result[@acp.AgentSpec, @acp.AgentCompositionError] {
  @acp.agent_spec(
    info={
      name: "cetas-memoh",
      title: Value("Cetas for Memoh"),
      version: self.version,
      meta: Omitted,
    },
    sessions=@acp.agent_session_service(
      new_session=(context, params) => self.handle_new_session(context, params),
      prompt=(context, params) => self.handle_prompt(context, params),
      cancel=(context, params) => self.handle_cancel(context, params),
      close=(context, params) => self.handle_close(context, params),
      set_config_option=(context, params) => {
        self.handle_set_config_option(context, params)
      },
    ),
    support=@memoh.memoh_agent_support(),
  )
}

///|
pub async fn MemohHost::handle_new_session(
  self : MemohHost,
  context : @acp.AgentContext,
  params : @acp.NewSessionParams,
) -> @acp.NewSessionResult raise @acp.HandlerError {
  @memoh.require_memoh_client((context.client_info)()) catch {
    error =>
      raise @acp.HandlerError::InvalidParams(
        message="cetas-memoh: " + memoh_error_detail(error),
      )
  }
  let session_id = mint_memoh_session_id()
  let session = match (self.spawn_session)(params) {
    Ok(session) => session
    Err(message) =>
      raise @acp.HandlerError::Application(message="cetas-memoh: " + message)
  }
  session.bridge.attach(context~, session_id~)
  self.sessions[session_id] = session
  {
    session_id,
    modes: Omitted,
    config_options: Value(memoh_config_options(session.router)),
    meta: Omitted,
  }
}

///|
fn prompt_failure_detail(error : Error) -> String {
  let raw = error.to_string()
  if raw.length() <= 384 {
    raw
  } else {
    raw[:384].to_owned() + "...(truncated)"
  }
}

///|
pub async fn MemohHost::handle_prompt(
  self : MemohHost,
  context : @acp.AgentContext,
  params : @acp.PromptParams,
) -> @acp.PromptResult raise @acp.HandlerError {
  let session = self.require_session(params.session_id)
  session.turn_lock.acquire()
  defer session.turn_lock.release()

  match self.sessions.get(params.session_id) {
    Some(live) if physical_equal(live, session) => ()
    _ =>
      raise @acp.HandlerError::InvalidParams(
        message="cetas-memoh: session closed while prompt was queued",
      )
  }

  session.bridge.attach(context~, session_id=params.session_id)
  session.bridge.set_context_window(router_context_window(session.router))
  let decoded = @memoh.decode_memoh_prompt(params.prompt) catch {
    error =>
      raise @acp.HandlerError::InvalidParams(
        message="cetas-memoh: " + memoh_error_detail(error),
      )
  }
  let message = session.memoh.prepare_turn(decoded)
  defer session.memoh.clear_turn_context()

  let outcome : Result[@acp.PromptResult, @acp.HandlerError] = @async.with_task_group(group => {
      session.bridge.spawn_pump(group)
      let task = group.spawn(
        () => session.agent.run_turn(message, params.session_id),
        allow_failure=true,
      )
      session.in_flight = Some(task)
      let failure : Error? = try {
        let _ = task.wait()
        None
      } catch {
        error => Some(error)
      }
      session.in_flight = None
      ignore(session.bridge.flush())
      session.bridge.close()
      match failure {
        None =>
          Ok({ stop_reason: session.bridge.stop_reason(), meta: Omitted, })
        Some(error) => {
          let detail = prompt_failure_detail(error)
          memoh_warn(
            "cetas-memoh: prompt failed (session=" +
            params.session_id +
            "): " +
            detail +
            "\n",
          )
          Err(@acp.HandlerError::Application(message="cetas-memoh: " + detail))
        }
      }
    },
  ) catch {
    _ =>
      Err(
        @acp.HandlerError::Application(
          message="cetas-memoh: internal task-group failure",
        ),
      )
  }
  match outcome {
    Ok(result) => result
    Err(error) => raise error
  }
}

///|
pub async fn MemohHost::handle_set_config_option(
  self : MemohHost,
  context : @acp.AgentContext,
  params : @acp.SetSessionConfigOptionParams,
) -> @acp.SetSessionConfigOptionResult raise @acp.HandlerError {
  let session = self.require_session(params.session_id)
  session.turn_lock.acquire()
  defer session.turn_lock.release()
  match self.sessions.get(params.session_id) {
    Some(live) if physical_equal(live, session) => ()
    _ =>
      raise @acp.HandlerError::InvalidParams(
        message="cetas-memoh: session closed while config update was queued",
      )
  }
  match
    apply_memoh_config_option(
      session.router,
      session.bridge,
      params.config_id,
      params.value,
    ) {
    Ok(config_options) => {
      context.session_update({
        session_id: params.session_id,
        update: @acp.SessionUpdate::ConfigOptionUpdate({
          config_options,
          meta: Omitted,
        }),
        meta: Omitted,
      }) catch {
        _ =>
          memoh_warn(
            "cetas-memoh: config_option_update push failed (session=" +
            params.session_id +
            ")\n",
          )
      }
      { config_options, meta: Omitted, }
    }
    Err(message) =>
      raise @acp.HandlerError::Application(
        message="cetas-memoh: " + message,
      )
  }
}

///|
pub async fn MemohHost::handle_cancel(
  self : MemohHost,
  _context : @acp.AgentContext,
  params : @acp.CancelParams,
) -> Unit {
  @async.sleep(0)
  match self.sessions.get(params.session_id) {
    Some(session) =>
      match session.in_flight {
        Some(task) => task.cancel()
        None => ()
      }
    None => ()
  }
}

///|
async fn MemohHost::retire(
  self : MemohHost,
  session_id : String,
  session : MemohSession,
) -> Unit noraise {
  ignore(self.sessions.remove(session_id))
  match session.in_flight {
    Some(task) => {
      task.cancel()
      try {
        let _ = task.wait()
      } catch {
        _ => ()
      }
    }
    None => ()
  }
  session.agent.shutdown() catch {
    error =>
      memoh_warn(
        "cetas-memoh: session shutdown failed (session=" +
        session_id +
        "): " +
        error.to_string() +
        "\n",
      )
  }
  session.memoh.clear_turn_context()
  session.bridge.detach()
}

///|
pub async fn MemohHost::handle_close(
  self : MemohHost,
  _context : @acp.AgentContext,
  params : @acp.CloseSessionParams,
) -> @acp.CloseSessionResult {
  match self.sessions.get(params.session_id) {
    Some(session) => self.retire(params.session_id, session)
    None => ()
  }
  { meta: Omitted, }
}

///|
pub async fn MemohHost::shutdown(self : MemohHost) -> Unit noraise {
  let snapshot : Array[(String, MemohSession)] = []
  for pair in self.sessions {
    snapshot.push(pair)
  }
  for pair in snapshot {
    self.retire(pair.0, pair.1)
  }
}
