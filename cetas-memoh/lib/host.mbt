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
  mut seq : Int32
}

///|
let session_id_state : SessionIdState = { last_ms: 0L, seq: 0, }

///|
/// Every id this runtime mints carries this prefix, and `session/resume`
/// accepts nothing else. A resumed id is one Memoh stored from an earlier
/// `session/new`, so an id without the prefix means the host is replaying a
/// different agent's state — louder to reject than to serve.
const MEMOH_SESSION_ID_PREFIX : String = "cetas-memoh-"

///|
fn mint_memoh_session_id() -> String {
  let now = @async.now()
  if now > session_id_state.last_ms {
    session_id_state.last_ms = now
    session_id_state.seq = 0
    MEMOH_SESSION_ID_PREFIX + now.to_string()
  } else {
    session_id_state.seq += 1
    MEMOH_SESSION_ID_PREFIX +
    now.to_string() +
    "-" +
    session_id_state.seq.to_string()
  }
}

///|
/// Memoh registers a session's tool-gateway route just after it starts that
/// session (felinics/Memoh#1717 taught the bridge to wait up to five seconds
/// for the registration). A single connect attempt can therefore lose a race
/// it would win moments later, so composition retries inside the same order of
/// magnitude before falling back to a session without platform tools.
const MEMOH_TOOLS_CONNECT_ATTEMPTS : Int32 = 3

///|
/// Delay before each retry, shortest first: ~0.3s and ~1.0s. A gateway that is
/// genuinely down costs about a second; a route that appears late costs
/// nothing the user notices. An Array is not a valid `const` type, so this one
/// stays a `let`.
let memoh_tools_connect_backoff_ms : Array[Int32] = [300, 1000]

///|
fn validate_resume_session_id(session_id : String) -> Result[Unit, String] {
  if !session_id.has_prefix(MEMOH_SESSION_ID_PREFIX) {
    return Err("unexpected session id '" + session_id + "'")
  }
  if session_id.length() == MEMOH_SESSION_ID_PREFIX.length() {
    return Err("session id carries no mint timestamp")
  }
  Ok(())
}

///|
fn router_context_window(router : @llm.RouterModelPort) -> Int32? {
  router.provider_config().context_window
}

///|
/// `tools_note` is empty for a fully equipped session. When Memoh Tools are
/// unavailable it carries the honest degradation: the conversation still
/// works, but no platform action may be claimed.
fn memoh_system_prompt(tools_note : String) -> String {
  let base = "You are Cetas running as a first-class Memoh agent runtime. " +
    "Memoh is the authority for conversation continuity, workspace/platform " +
    "operations, memory, and host authorization. Current-turn Memoh context " +
    "is supplied separately from the user's message. Use Memoh Tools for " +
    "platform and workspace actions; do not invent a parallel host state. " +
    "For Cetas identity, usage, or configuration questions, activate the " +
    "matching built-in manual first: cetas-about, cetas-usage, or " +
    "cetas-memoh-config."
  if tools_note.is_empty() {
    base
  } else {
    base +
    "\n\n" +
    tools_note +
    " This session has no Memoh Tools access: do not claim to have read, " +
    "changed, or executed anything on the host. Answer from the conversation " +
    "only, and say the platform tools are unavailable when asked to act."
  }
}

///|
pub struct MemohHost {
  version : String
  cwd : String
  catalogs : Array[@llm.ProviderModelCatalog]
  model_metadata : @llm.ModelMetadata
  credential_store : @credentials.FileProviderCredentialStore
  mcp_group : @async.TaskGroup[Unit]
  priv sessions : Map[String, MemohSession]
}

///|
pub async fn MemohHost::MemohHost(
  home~ : String,
  cwd~ : String,
  mcp_group~ : @async.TaskGroup[Unit],
  version~ : String = "0.1.0",
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
  {
    version,
    cwd,
    catalogs: platform.catalogs,
    model_metadata: @llm.ModelMetadata(
      store=Some(MemohModelMetadataStore::{ fs, home, }),
      warn=message => memoh_warn(message + "\n"),
    ),
    credential_store: platform.credential_store,
    mcp_group,
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
async fn close_failed_mcp_bridge(bridge : @mcp.MCPToolBridge) -> Unit noraise {
  let _ = @async.protect_from_cancel(() => bridge.close()) catch { _ => () }
}

///|
/// Connect one session's Memoh Tools bridge, retrying inside the bounded window
/// above. Each attempt gets a fresh bridge: a half-registered connection must
/// never be reused, and `close()` is what releases the failed one.
async fn MemohHost::connect_tools_with_retry(
  self : MemohHost,
  gateway : @mcp.MCPServerConfig,
) -> Result[@mcp.MCPToolBridge, String] noraise {
  let mut last = ""
  for attempt = 0; attempt < MEMOH_TOOLS_CONNECT_ATTEMPTS; attempt = attempt + 1 {
    let candidate = @mcp.MCPToolBridge()
    let result : Result[Unit, String] = candidate.connect(
      gateway,
      self.mcp_group,
    ) catch {
      error => Err(error.to_string())
    }
    match result {
      Ok(_) => return Ok(candidate)
      Err(message) => {
        close_failed_mcp_bridge(candidate)
        last = message
        if attempt + 1 < MEMOH_TOOLS_CONNECT_ATTEMPTS {
          @async.sleep(memoh_tools_connect_backoff_ms[attempt])
        }
      }
    }
  }
  Err(last)
}

///|
async fn MemohHost::build_session(
  self : MemohHost,
  mcp_servers : @acp.ProtocolNullable[Array[@acp.McpServer]],
) -> Result[MemohSession, String] noraise {
  let router = @llm.RouterModelPort::from_catalogs(
    self.catalogs,
    model_metadata=Some(self.model_metadata),
    provider_credential_store=Some(self.credential_store),
  ) catch {
    error => return Err("model router composition failed: " + error.to_string())
  }
  let memoh = @memoh.Memoh()
  let bridge = @ext_acp.AcpBridge(context_window=router_context_window(router))
  // Memoh opens two shapes of session on this runtime. A conversation always
  // carries the Memoh Tools HTTP gateway; a transient probe session (the
  // model/effort picker reads its options this way) carries no MCP
  // declaration at all and never prompts. Losing tools therefore must not
  // delete the session: keep the conversation, tell the model the truth, and
  // fail only on a declaration we cannot honour.
  let gateway_result : Result[@mcp.MCPServerConfig, @memoh.MemohError] = Ok(
    @memoh.memoh_tools_mcp_config(mcp_servers),
  ) catch {
    error => Err(error)
  }
  let mut tools_note = ""
  let mut tools_diagnostic = ""
  let mcp_tools : @mcp.MCPToolBridge? = match gateway_result {
    Err(@memoh.MemohError::MissingToolGateway) => {
      tools_note = "No Memoh Tools gateway was declared for this session."
      tools_diagnostic = tools_note
      None
    }
    Err(error) =>
      return Err("Memoh Tools contract failed: " + memoh_error_detail(error))
    Ok(gateway) =>
      match self.connect_tools_with_retry(gateway) {
        Ok(bridge) => Some(bridge)
        Err(message) => {
          // The prompt states the loss; the transport detail stays on stderr so
          // an internal endpoint or bridge diagnostic never reaches the model.
          tools_note = "Memoh Tools could not be reached for this session."
          tools_diagnostic = tools_note + " " + clipped(message, 200)
          None
        }
      }
  }
  // Memoh owns the workspace/platform surface. Keep only product/self-management
  // capabilities local, and fold the (potentially large) Memoh Tools MCP
  // catalog behind LazyTools without dropping the bridge's lifecycle ports.
  let fs_impl = @workspace.NativeWorkspaceFs()
  let fs : &@workspace.WorkspaceFs = fs_impl
  let manual_catalog = @skills.SkillCatalog::{
    skills: memoh_builtin_skills(),
    diagnostics: [],
  }
  let skills_ext = match
    @skills.Skills::from_catalog(fs, catalog=manual_catalog) {
    Ok(value) => value
    Err(message) => {
      match mcp_tools {
        Some(value) => close_failed_mcp_bridge(value)
        None => ()
      }
      return Err("built-in manual composition failed: " + message)
    }
  }
  let ask = @askquestion.AskQuestionTools()
  let exts : Array[&@posoco.Extension] = [
    router as &@posoco.Extension,
    memoh as &@posoco.Extension,
    bridge as &@posoco.Extension,
    skills_ext as &@posoco.Extension,
    ask as &@posoco.Extension,
  ]
  match mcp_tools {
    Some(mcp_bridge) => {
      let mcp_ext : &@posoco.Extension = mcp_bridge
      let (lazy_gateway, mcp_views) = match
        @lazytools.LazyTools::defer_extensions(exts=[mcp_ext]) {
        Ok(value) => value
        Err(message) => {
          close_failed_mcp_bridge(mcp_bridge)
          return Err("Memoh Tools lazy catalog failed: " + message)
        }
      }
      for view in mcp_views {
        exts.push(view)
      }
      exts.push(lazy_gateway as &@posoco.Extension)
    }
    None => ()
  }
  if !tools_note.is_empty() {
    memoh_warn("cetas-memoh: degraded session: " + tools_diagnostic + "\n")
  }
  let config = @posoco.agent_config(
    temperature=Some(0.0),
    system_prompt=Some(memoh_system_prompt(tools_note)),
  )
  let agent = @posoco.Agent(exts~, config~) catch {
    error => {
      match mcp_tools {
        Some(value) => close_failed_mcp_bridge(value)
        None => ()
      }
      return Err("agent composition failed: " + error.to_string())
    }
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
// ACP composition exposes a Result-valued registration contract. Preserve
// this ordinary failure outcome rather than changing the host API to throws.
#warnings("-result_error_return")
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
      resume_session=(context, params) => {
        self.handle_resume_session(context, params)
      },
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
  let session = match self.build_session(Value(params.mcp_servers)) {
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
/// Release a built session that lost a registration race. The map still owns
/// the winner under this id, so nothing may be removed here.
async fn discard_session(session : MemohSession) -> Unit noraise {
  session.agent.shutdown() catch {
    error =>
      memoh_warn(
        "cetas-memoh: discarded session shutdown failed: " +
        error.to_string() +
        "\n",
      )
  }
  session.memoh.clear_turn_context()
}

///|
/// `session/resume` — Memoh reattaching a conversation it already owns to a
/// new runtime process.
///
/// Memoh replaces the ACP process whenever the launch configuration changes,
/// the runtime is idle-reaped, the container restarts, or the server restarts,
/// and then asks the agent to continue its own session. This runtime keeps no
/// transcript (Memoh injects the conversation per turn), so a resume replays
/// nothing: it rebuilds the same live objects under the stored id and returns
/// the same options `session/new` would. That is the honest meaning of
/// "the agent's own session" here — the process changed, the conversation did
/// not.
///
/// `cwd` is deliberately ignored: every file and command in this composition
/// runs through Memoh Tools, so the working directory belongs to the host.
pub async fn MemohHost::handle_resume_session(
  self : MemohHost,
  context : @acp.AgentContext,
  params : @acp.ResumeSessionParams,
) -> @acp.ResumeSessionResult raise @acp.HandlerError {
  @memoh.require_memoh_client((context.client_info)()) catch {
    error =>
      raise @acp.HandlerError::InvalidParams(
        message="cetas-memoh: " + memoh_error_detail(error),
      )
  }
  match validate_resume_session_id(params.session_id) {
    Ok(_) => ()
    Err(reason) =>
      raise @acp.HandlerError::InvalidParams(message="cetas-memoh: " + reason)
  }
  // Resume is idempotent: a session already live in this process keeps its
  // objects, so its router keeps the model/effort it had switched to.
  let session = match self.sessions.get(params.session_id) {
    Some(live) => live
    None => {
      let built = match self.build_session(params.mcp_servers) {
        Ok(session) => session
        Err(message) =>
          raise @acp.HandlerError::Application(
            message="cetas-memoh: " + message,
          )
      }
      match self.sessions.get(params.session_id) {
        Some(live) => {
          discard_session(built)
          live
        }
        None => {
          self.sessions[params.session_id] = built
          built
        }
      }
    }
  }
  session.bridge.attach(context~, session_id=params.session_id)
  session.bridge.set_context_window(router_context_window(session.router))
  {
    modes: Omitted,
    config_options: Value(memoh_config_options(session.router)),
    meta: Omitted,
  }
}

///|
/// A cancelled turn reaches this host in two shapes, and both are a
/// cancellation rather than a failure: the awaited task was cancelled from
/// outside (pause/unwind before the turn produced its own terminal), or the
/// turn unwound internally and reported `AgentError::Cancelled`. Reporting the
/// second as an application error would answer ACP with a failure for a turn
/// the user cancelled, so both must settle as `StopReason::Cancelled`.
fn prompt_failure_is_cancelled(error : Error) -> Bool {
  if error is @async.WaitedTaskAlreadyCancelled {
    return true
  }
  error is @posoco.AgentError::Cancelled(_)
}

///|
/// Bound a third-party message before it reaches stderr, a prompt, or an ACP
/// error, so a pathological transport message cannot flood the wire.
fn clipped(text : String, limit : Int32) -> String {
  if text.length() <= limit {
    text
  } else {
    text[:limit].to_owned() + "...(truncated)"
  }
}

///|
fn prompt_failure_detail(error : Error) -> String {
  clipped(error.to_string(), 384)
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
        Some(error) =>
          if prompt_failure_is_cancelled(error) {
            Ok({ stop_reason: @acp.StopReason::Cancelled, meta: Omitted, })
          } else {
            let detail = prompt_failure_detail(error)
            memoh_warn(
              "cetas-memoh: prompt failed (session=" +
              params.session_id +
              "): " +
              detail +
              "\n",
            )
            Err(
              @acp.HandlerError::Application(message="cetas-memoh: " + detail),
            )
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
      raise @acp.HandlerError::Application(message="cetas-memoh: " + message)
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
