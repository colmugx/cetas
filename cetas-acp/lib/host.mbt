///|
/// CetasAcpHost — the ACP host state for one cetas agent process. One
/// private `SessionHandle` per ACP session (prompts serialize per session
/// via the handle's `turn_lock`, so distinct sessions run concurrently);
/// process-level state is assembled once by `build_platform` and shared;
/// mode/effort selection is session-runtime state the sidecar never carries.

///|
/// One live ACP session's private machinery; its bridge is bound to it for
/// life (the ext-acp contract).
priv struct SessionHandle {
  bridge : @ext_acp.AcpBridge
  router : @llm.RouterModelPort
  agent : @posoco.Agent
  /// The session's working directory (params.cwd, else process cwd), for the sidecar.
  cwd : String
  /// The session's per-project store: history persists here and the /name
  /// command runs against it.
  store : @fs_session.JsonlSessionStore
  /// The project bucket directory backing `store`; the sidecar lives beside
  /// the history inside it.
  project_dir : String
  plan : @plan.PlanMode
  /// The `permission` config option reads and switches this policy's mode.
  permission : @permission.PermissionPolicy
  /// The fs delegate when `CETAS_DELEGATE_FS=host`; its context mirrors
  /// `context` (see `set_handle_context`) so reads/writes ride the client.
  fs_delegate : AcpDelegateFs?
  /// Outbound context, refreshed each prompt, so refresh can push config_option_update.
  mut context : @acp.AgentContext?
  /// In-flight turn task, so `session/cancel` can interrupt it.
  mut in_flight : @async.Task[@posoco.TurnResult]?
  /// Held from before bridge attach until the whole turn lifecycle settles,
  /// so a queued prompt runs strictly after instead of interleaving turns.
  turn_lock : @async.Mutex
  /// Mode id last reported, so mode pushes only fire on an actual move.
  mut last_mode_id : String
}

// ------------------------------------------------------- session id minting

///|
/// Process-global (not per host) so two hosts in one process cannot mint the same id.
priv struct DurableIdState {
  mut last_ms : Int64
  mut last_seq : Int
}

///|
let durable_id_state : DurableIdState = { last_ms: 0L, last_seq: -1, }

///|
/// `cetas-<epoch-ms>`, with a `-<seq>` suffix once mints outpace the clock;
/// the sequence only grows, so ids stay fresh across a clock regression.
/// Shape passes ext-fs-session's `validate_session_id` (safe JSONL stem).
fn mint_session_id() -> String {
  let now = @async.now()
  let state = durable_id_state
  if now > state.last_ms {
    state.last_ms = now
    state.last_seq = 0
    "cetas-\{now}"
  } else {
    state.last_seq += 1
    "cetas-\{now}-\{state.last_seq}"
  }
}

///|
/// ACP session ids double as Posoco session ids (no id mapping table);
/// clock-minted (`mint_session_id`), so a restart never re-mints a live id.
pub struct CetasAcpHost {
  version : String
  /// Cetas home (`~/.cetas`), where the selection is persisted.
  home : String
  /// The same fs instance the assembly used, so tests can substitute a fake.
  fs : &@workspace.WorkspaceFs
  priv sessions : Map[String, SessionHandle]
  /// The load/resume/list view of persisted history; tests may use a scratch root.
  priv session_store : @fs_session.JsonlSessionStore
  /// One cached store per project bucket, keyed by `project_dir_name(cwd)`;
  /// `session/new` resolves the session's store through it so a session and
  /// its bucket never disagree across the host's lifetime.
  priv stores : Map[String, @fs_session.JsonlSessionStore]
  /// The fallback a sidecar-less session advertises in `session/list`.
  priv process_cwd : String
  /// Production wires `build_session_agent`; tests substitute lightweight
  /// assemblies.
  priv spawn_session : async (String, @acp.NewSessionParams) -> Result[
    SessionHandle,
    String,
  ]
  /// Shared with the platform; the lazy refresh swaps entries in place for
  /// later sessions.
  priv catalogs : Array[@llm.ProviderModelCatalog]
  /// Refresh seams plus snapshot for the lazy refresh; tests substitute
  /// fakes via `CetasAcpHost::of`.
  refreshables : Array[&@llm.RefreshableProviderFactory]
  refresh_snapshot : @cetas_core.ProviderCredentialSnapshot
  /// The wire debug tap (`CETAS_DEBUG_WIRE`, see debug.mbt).
  priv wire_log : Bool
  /// The wire append path: true when `fs` is the process-native fs, so
  /// records take the O(1) `@fs` open-append-write; fakes (tests) take the
  /// read-modify-write workspace-fs path so they observe every record.
  priv wire_native_append : Bool
}

///|
/// Compose the production host: the platform is built once and every
/// `session/new` assembles a fresh agent over it; fails loudly with no
/// provider configured. `mcp_group` must outlive the agent (stdio MCP).
pub async fn CetasAcpHost::CetasAcpHost(
  home~ : String,
  cwd~ : String,
  agent_version? : String = "0.1.0",
  mcp_group? : @async.TaskGroup[Unit],
  mcp_mode? : @mcp.LoadMode = @mcp.LoadMode::Lazy,
) -> CetasAcpHost raise @posoco.CompositionError {
  let fs = @workspace.NativeWorkspaceFs()
  let platform = build_platform(
    home~,
    cwd~,
    fs,
    mcp_group~,
    mcp_mode~,
    delegation=startup_delegation_mode(),
    debug=startup_debug_taps(),
  )
  // Shared with the spawn closure so every session of one cwd composes over
  // the same store instance the host hands out for that bucket.
  let stores : Map[String, @fs_session.JsonlSessionStore] = Map::from_array([])
  let spawn_session = async fn(
    session_id : String,
    params : @acp.NewSessionParams,
  ) -> Result[SessionHandle, String] {
    // The session anchors to params.cwd (process cwd when empty); the cwd
    // flows through the whole assembly; injected MCP names pick the profile.
    let cwd = if params.cwd.length() > 0 { params.cwd } else { platform.cwd }
    let store = cached_project_store(stores, home=platform.home, cwd~)
    Ok(
      build_session_agent(
        platform~,
        cwd~,
        session_id~,
        session_store=store,
        mcp_servers=params.mcp_servers,
        host_kind=detect_host_kind(acp_mcp_server_names(params.mcp_servers)),
      ),
    ) catch {
      error => Err(error.to_string())
    }
  }
  {
    spawn_session,
    version: agent_version,
    home,
    fs,
    sessions: Map::from_array([]),
    session_store: platform.session_store,
    stores,
    process_cwd: cwd,
    catalogs: platform.catalogs,
    refreshables: platform.refreshables,
    refresh_snapshot: platform.refresh_snapshot,
    wire_log: platform.debug.wire,
    wire_native_append: true,
  }
}

///|
/// Plan review over a plan-specific `session/request_permission` with named
/// options — editors render each option's name as a button, not a generic card.
priv struct AcpPlanReview {
  bridge : @ext_acp.AcpBridge
}

///|
/// Option ids the client echoes back in `SelectedPermissionOutcome.option_id`.
const PLAN_OPTION_APPROVE = "plan-approve"

///|
const PLAN_OPTION_KEEP_PLANNING = "plan-keep-planning"

///|
const PLAN_OPTION_AUTO_EDIT = "plan-auto-edit"

///|
/// One pending tool-call update titled with an 80-char plan preview,
/// carrying the full plan as `raw_input`, plus the three named options.
fn acp_plan_request(
  session_id : String,
  request : @plan.PlanReviewRequest,
) -> @acp.RequestPermissionRequest {
  let preview = if request.plan.length() <= 80 {
    request.plan
  } else {
    request.plan.sub(end=77).to_owned() + "..."
  }
  {
    session_id,
    tool_call: {
      tool_call_id: "plan-review",
      kind: Value(@ext_acp.acp_tool_kind("exit_plan_mode")),
      status: Value(Pending),
      title: Value(preview),
      content: Omitted,
      locations: Omitted,
      raw_input: Value(Json::object({ "plan": Json::string(request.plan) })),
      raw_output: Omitted,
      meta: Omitted,
    },
    options: [
      {
        option_id: PLAN_OPTION_APPROVE,
        name: "Approve plan",
        kind: AllowOnce,
        meta: Omitted,
      },
      {
        option_id: PLAN_OPTION_KEEP_PLANNING,
        name: "Keep planning",
        kind: RejectOnce,
        meta: Omitted,
      },
      {
        option_id: PLAN_OPTION_AUTO_EDIT,
        name: "Auto-edit (approve & stop asking)",
        kind: AllowAlways,
        meta: Omitted,
      },
    ],
    meta: Omitted,
  }
}

///|
/// Every failure mode keeps planning (`Revise`), never `Dismiss` — an
/// accidental Escape must not kill the turn. `plan-auto-edit`'s `AllowAlways`
/// maps to plain `Accept` (the "always" memory lives client-side).
fn acp_plan_decision(
  response : @acp.RequestPermissionResponse,
) -> @plan.PlanReviewDecision {
  match response.outcome {
    Selected(outcome) =>
      if outcome.option_id == PLAN_OPTION_APPROVE {
        @plan.PlanReviewDecision::Accept
      } else if outcome.option_id == PLAN_OPTION_AUTO_EDIT {
        @plan.PlanReviewDecision::Accept
      } else if outcome.option_id == PLAN_OPTION_KEEP_PLANNING {
        @plan.PlanReviewDecision::Revise(
          feedback="The user chose to keep planning. Ask what to change or refine the plan.",
        )
      } else {
        @plan.PlanReviewDecision::Revise(
          feedback="The plan review returned an unrecognized choice ('\{@devkit.sanitize_label(outcome.option_id)}'). Ask what to change or refine the plan.",
        )
      }
    Cancelled =>
      @plan.PlanReviewDecision::Revise(
        feedback="The plan review was dismissed. Continue planning.",
      )
  }
}

///|
impl @plan.PlanReviewSource for AcpPlanReview with fn review(
  self,
  request : @plan.PlanReviewRequest,
) -> @plan.PlanReviewDecision {
  match (self.bridge.context, self.bridge.session_id()) {
    (Some(context), Some(session_id)) => {
      // Flush first so streamed plan text reaches the client before the decision UI.
      ignore(self.bridge.flush())
      let response = context.request_permission(
        acp_plan_request(session_id, request),
      ) catch {
        // A transport failure must not end the turn: fall back to planning.
        _ =>
          return @plan.PlanReviewDecision::Revise(
            feedback="plan review request failed; continuing planning",
          )
      }
      acp_plan_decision(response)
    }
    // Unreachable in practice; a detached bridge must never kill the turn.
    _ => @plan.PlanReviewDecision::Revise(feedback="plan review unavailable")
  }
}

///|
/// Capabilities are derived from service presence inside `colmugx/acp`;
/// `mcp_http=true` must be advertised or the protocol gate rejects injected
/// HTTP MCP servers before the handler runs (SSE: no ext-mcp SSE client).
pub fn CetasAcpHost::agent_spec(
  self : CetasAcpHost,
) -> Result[@acp.AgentSpec, @acp.AgentCompositionError] {
  @acp.agent_spec(
    info={
      name: "cetas",
      title: Value("Cetas"),
      version: self.version,
      meta: Omitted,
    },
    sessions=@acp.agent_session_service(
      new_session=(context, params) => self.handle_new_session(context, params),
      prompt=(context, params) => self.handle_prompt(context, params),
      cancel=(context, params) => self.handle_cancel(context, params),
      close=(context, params) => self.handle_close(context, params),
      load=(context, params) => self.handle_load_session(context, params),
      resume_session=(context, params) => {
        self.handle_resume_session(context, params)
      },
      fork_session=(context, params) => {
        self.handle_fork_session(context, params)
      },
      list=(context, params) => self.handle_list_sessions(context, params),
      delete=(context, params) => self.handle_delete_session(context, params),
      set_config_option=(context, params) => {
        self.handle_set_config_option_sidecar(context, params)
      },
      set_mode=(context, params) => self.handle_set_mode(context, params),
    ),
    support=@acp.agent_support(prompt_image=true, mcp_http=true),
  )
}

///|
/// The two ACP session modes cetas advertises: the plain agent surface and
/// ext-plan's planning state machine — the editor's mode selector drives the
/// same state machine the model's `enter_plan_mode` tool and `/plan` do.
const ACP_MODE_DEFAULT_ID = "default"

///|
const ACP_MODE_PLAN_ID = "plan"

///|
fn acp_available_modes() -> Array[@acp.SessionMode] {
  [
    {
      id: ACP_MODE_DEFAULT_ID,
      name: "Default",
      description: Omitted,
      meta: Omitted,
    },
    {
      id: ACP_MODE_PLAN_ID,
      name: "Plan",
      description: Value(
        "Read-only research and plan drafting; changes wait until the plan is approved",
      ),
      meta: Omitted,
    },
  ]
}

///|
/// `Planning`/`ReadyForApproval` are both "plan" — an awaiting plan is still planning.
fn acp_mode_id_of(plan : @plan.PlanMode) -> String {
  match plan.status() {
    Off => ACP_MODE_DEFAULT_ID
    _ => ACP_MODE_PLAN_ID
  }
}

///|
/// Mode is runtime state, never in the sidecar — a restored session re-advertises `default`.
fn acp_modes_block(current : String) -> @acp.SessionModeState {
  {
    current_mode_id: current,
    available_modes: acp_available_modes(),
    meta: Omitted,
  }
}

///|
/// Unknown ids reject invalid params — no cross-session fallback may improvise state.
fn CetasAcpHost::require_session(
  self : CetasAcpHost,
  session_id : String,
) -> SessionHandle raise @acp.HandlerError {
  match self.sessions.get(session_id) {
    Some(handle) => handle
    None =>
      raise @acp.HandlerError::InvalidParams(
        message="cetas-acp: unknown session '" + session_id + "'",
      )
  }
}

///|
/// `session/new`: mint a fresh session id shared by both bridge sides and
/// assemble the agent over the process platform. With a seeded model cache
/// the full list is announced; otherwise refresh pushes `config_option_update`.
pub async fn CetasAcpHost::handle_new_session(
  self : CetasAcpHost,
  context : @acp.AgentContext,
  params : @acp.NewSessionParams,
) -> @acp.NewSessionResult raise @acp.HandlerError {
  let session_id = mint_session_id()
  self.debug_wire_in(
    session_id~,
    rpc_method="session/new",
    params=debug_new_session_params(params),
  )
  // Only an async-machinery defect folds into this failure channel.
  let spawned : Result[SessionHandle, String] = (self.spawn_session)(
    session_id, params,
  ) catch {
    error => Err(error.to_string())
  }
  let handle = match spawned {
    Ok(handle) => handle
    Err(message) =>
      raise @acp.HandlerError::Application(
        message="cetas-acp: session assembly failed: " + message,
      )
  }
  // The host mints the id, so it stamps every handle's plan label.
  handle.plan.set_session_name(session_id)
  let context = self.debug_tap_context(context)
  set_handle_context(handle, context)
  self.sessions[session_id] = handle
  // Best-effort sidecar record (cwd, router selection, injected MCP names)
  // for later load/resume/list; failure never fails session/new.
  let mcp_names : Array[String] = []
  for server in params.mcp_servers {
    mcp_names.push(acp_mcp_server_name(server))
  }
  self.update_session_sidecar(session_id, handle, mcp_names)
  {
    session_id,
    modes: Value(acp_modes_block(acp_mode_id_of(handle.plan))),
    config_options: Value(
      build_config_options(handle.router, handle.permission.mode),
    ),
    meta: Omitted,
  }
}

///|
fn acp_failure_detail(error : Error) -> String {
  let text = error.to_string()
  let chars : Array[Char] = []
  let mut truncated = false
  for char in text {
    if chars.length() >= 256 {
      truncated = true
      break
    }
    match char {
      '\n' | '\r' => chars.push(' ')
      other => chars.push(other)
    }
  }
  let label = String::from_array(chars)
  if truncated {
    label + "...(truncated)"
  } else {
    label
  }
}

///|
/// `session/prompt`: one turn with live streaming, on the session's own agent
/// and bridge. Prompts serialize per session on `turn_lock` (a queued prompt
/// waits out the previous turn's whole lifecycle; cancel interrupts only the
/// active turn, never the queue); cancelled settles `stopReason: cancelled`.
pub async fn CetasAcpHost::handle_prompt(
  self : CetasAcpHost,
  context : @acp.AgentContext,
  params : @acp.PromptParams,
) -> @acp.PromptResult raise @acp.HandlerError {
  let handle = self.require_session(params.session_id)
  self.debug_wire_in(
    session_id=params.session_id,
    rpc_method="session/prompt",
    params=debug_prompt_params(params),
  )
  // acquire is cancellation safe: a prompt cancelled while queued settles
  // here — no turn runs, the bridge is never attached, nothing to unwind.
  handle.turn_lock.acquire() catch {
    error =>
      if @async.is_cancellation_error(error) {
        raise @acp.HandlerError::Cancelled
      } else {
        raise @acp.HandlerError::Application(
          message="cetas-acp: turn lock acquire failed (session=\{params.session_id})",
        )
      }
  }
  // Held until the whole turn lifecycle settles — the next prompt starts quiesced.
  defer handle.turn_lock.release()
  // The wait can outlive this handle: close/load/resume may retire exactly
  // this machinery while queued. Re-validate by identity (physical_equal —
  // a restored session may reuse the id) so a woken waiter fails as unknown.
  match self.sessions.get(params.session_id) {
    Some(live) if physical_equal(live, handle) => ()
    _ =>
      raise @acp.HandlerError::InvalidParams(
        message="cetas-acp: session '" +
          params.session_id +
          "' was closed while the prompt was queued",
      )
  }
  let context = self.debug_tap_context(context)
  set_handle_context(handle, context)
  handle.bridge.attach(context~, session_id=params.session_id)
  // A prompt naming a command the session store registers (`/name …`) runs
  // locally: no model round, the reply is the command's outcome.
  match
    dispatch_slash_command(
      session_id=params.session_id,
      handle,
      prompt=params.prompt,
    ) {
    Some(result) => {
      self.debug_wire_prompt_out(
        session_id=params.session_id,
        outcome=Ok(result),
      )
      return result
    }
    None => ()
  }
  let outcome : Result[@acp.PromptResult, @acp.HandlerError] = @async.with_task_group(group => {
      handle.bridge.spawn_pump(group)
      // allow_failure: the turn's AgentError is reported through task.wait()
      // below, so the pump and this handler still settle in order.
      let task = group.spawn(
        () => {
          handle.agent.run_turn(
            acp_prompt_to_message(params.prompt),
            params.session_id,
          )
        },
        allow_failure=true,
      )
      handle.in_flight = Some(task)
      let failure : Error? = try {
        let _ = task.wait()
        None
      } catch {
        error => Some(error)
      }
      handle.in_flight = None
      ignore(handle.bridge.flush())
      // The turn may have moved the mode on its own — sync before the pump closes.
      push_mode_update(params.session_id, handle)
      // A settled turn gives an unnamed session its first-user-text title;
      // named sessions already pushed at rename time.
      if failure is None {
        push_session_title(params.session_id, handle, only_unnamed=true)
      }
      handle.bridge.close()
      match failure {
        None => Ok({ stop_reason: handle.bridge.stop_reason(), meta: Omitted, })
        Some(error) =>
          if @async.is_cancellation_error(error) {
            Ok({ stop_reason: Cancelled, meta: Omitted, })
          } else {
            // The raised error's text carries the cause; the bridge's
            // TurnFailed text is category-only and never reaches the client.
            let detail = acp_failure_detail(error)
            acp_warn(
              "cetas-acp: session/prompt failed (session=\{params.session_id}): \{detail}\n",
            )
            Err(@acp.HandlerError::Application(message="cetas-acp: \{detail}"))
          }
      }
    },
  ) catch {
    // Only an unexpected pump defect reaches this arm (allow_failure above).
    error =>
      if @async.is_cancellation_error(error) {
        Err(@acp.HandlerError::Cancelled)
      } else {
        Err(
          @acp.HandlerError::Application(
            message="cetas-acp: internal task-group failure",
          ),
        )
      }
  }
  // The wire's last fact for the request lands after the bridge has closed,
  // so the settlement record never delays the response it describes.
  self.debug_wire_prompt_out(session_id=params.session_id, outcome~)
  match outcome {
    Ok(result) => result
    Err(error) => raise error
  }
}

///|
/// Push a `current_mode_update` on an actual mode move. The push rides the
/// outbound context directly — not the bridge queue — so it works even
/// outside a running pump; best-effort, and closed sessions never push.
async fn push_mode_update(
  session_id : String,
  handle : SessionHandle,
) -> Unit noraise {
  let current = acp_mode_id_of(handle.plan)
  if current == handle.last_mode_id {
    return
  }
  handle.last_mode_id = current
  match handle.context {
    Some(context) =>
      context.session_update({
        session_id,
        update: @acp.SessionUpdate::CurrentModeUpdate({
          current_mode_id: current,
          meta: Omitted,
        }),
        meta: Omitted,
      }) catch {
        _ =>
          acp_warn(
            "cetas-acp: current_mode_update push failed (session=" +
            session_id +
            ")\n",
          )
      }
    None => ()
  }
}

///|
/// Push the session's current title (user-chosen name first, else the first
/// user text) through the session's bridge. `only_unnamed` narrows the push
/// to sessions without a metadata name — named sessions already advertised
/// their title at rename time. Best-effort: a missing history (the store has
/// nothing persisted yet) or a closed bridge skips the push.
async fn push_session_title(
  session_id : String,
  handle : SessionHandle,
  only_unnamed~ : Bool,
) -> Unit noraise {
  let summary : Result[@fs_session.SessionSummary, Error] = Ok(
    handle.store.summary(session_id),
  ) catch {
    error => Err(error)
  }
  match summary {
    Ok(s) =>
      if !(only_unnamed && s.name is Some(_)) {
        handle.bridge.push_session_info_update(
          session_id~,
          title=@fs_session.display_title(s),
        )
      }
    Err(_) => ()
  }
}

///|
/// `session/set_mode`: `"plan"` enters via the same `/plan on` command path
/// (idempotent); `"default"` exits unconditionally — no review is deliberate
/// (a host switch is itself the user's decision). The client learns via push.
pub async fn CetasAcpHost::handle_set_mode(
  self : CetasAcpHost,
  _context : @acp.AgentContext,
  params : @acp.SetSessionModeParams,
) -> @acp.SetSessionModeResult raise @acp.HandlerError {
  let handle = self.require_session(params.session_id)
  self.debug_wire_in(
    session_id=params.session_id,
    rpc_method="session/set_mode",
    params=debug_set_mode_params(params),
  )
  match params.mode_id {
    ACP_MODE_PLAN_ID => {
      // A failure warns; the follow-up push reports the state that holds.
      let outcome : Result[@posoco.CommandOutcome, Error] = Ok(
        handle.plan.invoke("plan", Json::string("on")),
      ) catch {
        error => Err(error)
      }
      match outcome {
        Ok(@posoco.CommandOutcome::Success(..)) => ()
        Ok(@posoco.CommandOutcome::Failure(reason~)) =>
          acp_warn(
            "cetas-acp: set_mode 'plan' refused (session=" +
            params.session_id +
            "): " +
            reason +
            "\n",
          )
        Ok(_) => ()
        Err(error) =>
          acp_warn(
            "cetas-acp: set_mode 'plan' failed (session=" +
            params.session_id +
            "): " +
            error.to_string() +
            "\n",
          )
      }
    }
    ACP_MODE_DEFAULT_ID => handle.plan.stop()
    other =>
      raise @acp.HandlerError::InvalidParams(
        message="cetas-acp: unknown mode '" +
          other +
          "' (expected 'default' or 'plan')",
      )
  }
  push_mode_update(params.session_id, handle)
  { meta: Omitted, }
}

///|
/// Stamp the invocation context on the handle and (when delegating) the fs
/// delegate — one helper so the two mirrors can never drift.
fn set_handle_context(
  handle : SessionHandle,
  context : @acp.AgentContext,
) -> Unit {
  handle.context = Some(context)
  match handle.fs_delegate {
    Some(delegate) => delegate.attach(context~)
    None => ()
  }
}

///|
/// Cut the outbound contexts: no more config pushes; the fs delegate degrades to local.
fn clear_handle_context(handle : SessionHandle) -> Unit {
  handle.context = None
  match handle.fs_delegate {
    Some(delegate) => delegate.detach()
    None => ()
  }
}

///|
/// `session/cancel`: interrupt the in-flight turn; the prompt settles when the task unwinds.
pub async fn CetasAcpHost::handle_cancel(
  self : CetasAcpHost,
  _context : @acp.AgentContext,
  params : @acp.CancelParams,
) -> Unit {
  if self.sessions.contains(params.session_id) {
    self.debug_wire_in(
      session_id=params.session_id,
      rpc_method="session/cancel",
      params=debug_session_params(params.session_id),
    )
  }
  match self.sessions.get(params.session_id) {
    Some(handle) =>
      match handle.in_flight {
        Some(task) => task.cancel()
        None => ()
      }
    None => ()
  }
}

///|
/// Retire one live session through the close semantics: removed from the map
/// synchronously first (queued prompts re-validate and fail as unknown; a
/// refresh snapshot only captures the session fully alive or not at all),
/// then the turn is cancelled/drained before `Agent::shutdown`; a shutdown
/// failure only warns.
async fn CetasAcpHost::retire_live_session(
  self : CetasAcpHost,
  session_id : String,
  handle : SessionHandle,
) -> Unit noraise {
  ignore(self.sessions.remove(session_id))
  match handle.in_flight {
    Some(task) => {
      task.cancel()
      // Drain: the turn's own failure (the cancellation) belongs to
      // the prompt request it settles, not to the retirement.
      try {
        let _ = task.wait()
      } catch {
        _ => ()
      }
    }
    None => ()
  }
  handle.agent.shutdown() catch {
    error =>
      acp_warn(
        "cetas-acp: session shutdown failed (session=" +
        session_id +
        "): " +
        error.to_string() +
        "\n",
      )
  }
  // Cut the outbound context: a refresh that snapshotted before the removal
  // cannot push into a retired session; the fs delegate degrades to local.
  clear_handle_context(handle)
}

///|
/// `session/close`: retire one session; unknown id is a silent no-op (the
/// client may race a close it already believes done).
pub async fn CetasAcpHost::handle_close(
  self : CetasAcpHost,
  _context : @acp.AgentContext,
  params : @acp.CloseSessionParams,
) -> @acp.CloseSessionResult {
  match self.sessions.get(params.session_id) {
    None => { meta: Omitted, }
    Some(handle) => {
      self.debug_wire_in(
        session_id=params.session_id,
        rpc_method="session/close",
        params=debug_session_params(params.session_id),
      )
      self.retire_live_session(params.session_id, handle)
      { meta: Omitted, }
    }
  }
}

///|
/// A missing file stays absent, so delete is idempotent per file; a failed
/// removal raises an application error naming the file.
async fn CetasAcpHost::delete_persisted_file(
  self : CetasAcpHost,
  path : String,
  label : String,
  session_id : String,
) -> Unit raise @acp.HandlerError {
  let exists = self.fs.exists(path) catch { _ => false }
  if exists {
    self.fs.remove(path) catch {
      error =>
        raise @acp.HandlerError::Application(
          message="cetas-acp: failed to delete session " +
            session_id +
            " " +
            label +
            " (" +
            path +
            "): " +
            error.to_string(),
        )
    }
  }
}

///|
/// `session/delete`: retire a live session, then delete its JSONL history
/// and sidecar — unrecoverable. Unknown/malformed id rejects invalid params,
/// deliberately not the cancel/close silent no-op (a mistyped id must not hide).
pub async fn CetasAcpHost::handle_delete_session(
  self : CetasAcpHost,
  _context : @acp.AgentContext,
  params : @acp.DeleteSessionParams,
) -> @acp.DeleteSessionResult raise @acp.HandlerError {
  // Live first (fork posture): a session whose sidecar write failed and has
  // not turned is live. Its bucket comes from the handle before retirement
  // removes it; a closed session resolves through the candidate buckets.
  let project_dir = match self.sessions.get(params.session_id) {
    Some(handle) => {
      let dir = handle.project_dir
      self.retire_live_session(params.session_id, handle)
      dir
    }
    None => self.require_session_bucket(params.session_id)
  }
  self.debug_wire_in(
    session_id=params.session_id,
    rpc_method="session/delete",
    params=debug_session_params(params.session_id),
  )
  self.delete_persisted_file(
    @fs_session.jsonl_session_path(project_dir, params.session_id),
    "history",
    params.session_id,
  )
  match host_sidecar_path(project_dir, params.session_id) {
    Some(path) => self.delete_persisted_file(path, "sidecar", params.session_id)
    None => ()
  }
  { meta: Omitted, }
}

// -------------------------------------------------------------- host sidecar

///|
/// Empty strings and an empty roster mean "unknown" — a missing or corrupt
/// sidecar degrades to these defaults instead of failing the restore.
priv struct SessionSidecar {
  cwd : String
  model : String
  effort : String?
  mcp_servers : Array[String]
}

///|
fn sidecar_string_field(fields : Map[String, Json], key : String) -> String {
  match fields.get(key) {
    Some(Json::String(value)) => value
    _ => ""
  }
}

///|
fn sidecar_effort_field(fields : Map[String, Json]) -> String? {
  match fields.get("effort") {
    Some(Json::String(value)) => Some(value)
    _ => None
  }
}

///|
fn sidecar_mcp_names(fields : Map[String, Json]) -> Array[String] {
  let names : Array[String] = []
  match fields.get("mcp_servers") {
    Some(Json::Array(items)) =>
      for item in items {
        match item {
          Json::String(name) => names.push(name)
          _ => ()
        }
      }
    _ => ()
  }
  names
}

///|
/// Missing, unreadable, or malformed content is `None`, never an error; a
/// corrupt file warns once so the data loss stays observable.
async fn read_session_sidecar(
  fs : &@workspace.WorkspaceFs,
  project_dir~ : String,
  session_id~ : String,
) -> SessionSidecar? noraise {
  let path = match host_sidecar_path(project_dir, session_id) {
    Some(path) => path
    None => return None
  }
  match @workspace.read_file_result(fs, path) {
    Missing => None
    Failed(message) => {
      acp_warn(
        "cetas-acp: session sidecar unreadable (" +
        path +
        "): " +
        message +
        "; restoring defaults\n",
      )
      None
    }
    Content(text) => {
      let parsed : Result[Json, Error] = Ok(@json.parse(text)) catch {
        error => Err(error)
      }
      match parsed {
        Ok(Json::Object(fields)) =>
          Some({
            cwd: sidecar_string_field(fields, "cwd"),
            model: sidecar_string_field(fields, "model"),
            effort: sidecar_effort_field(fields),
            mcp_servers: sidecar_mcp_names(fields),
          })
        _ => {
          acp_warn(
            "cetas-acp: session sidecar is not a JSON object (" +
            path +
            "); restoring defaults\n",
          )
          None
        }
      }
    }
  }
}

///|
/// Refresh one session's sidecar from its live handle: model/effort come
/// from the router; cwd and the MCP roster survive from the existing sidecar
/// (the roster cannot be recomputed later); `fresh_mcp_names` seeds a fresh
/// one. Runs under the process persistence mutex; atomic and best-effort.
async fn CetasAcpHost::update_session_sidecar(
  self : CetasAcpHost,
  session_id : String,
  handle : SessionHandle,
  fresh_mcp_names : Array[String],
) -> Unit noraise {
  let path = match host_sidecar_path(handle.project_dir, session_id) {
    Some(path) => path
    None => {
      acp_warn(
        "cetas-acp: session sidecar write skipped (invalid session id)\n",
      )
      return
    }
  }
  acp_persist_mutex.acquire() catch {
    _ => {
      acp_warn(
        "cetas-acp: session sidecar write skipped (session=" +
        session_id +
        ")\n",
      )
      return
    }
  }
  // The body below has no early return, so the lock releases once at the end.
  let existing = read_session_sidecar(
    self.fs,
    project_dir=handle.project_dir,
    session_id~,
  )
  let cwd = match existing {
    Some({ cwd, .. }) => if cwd.length() > 0 { cwd } else { handle.cwd }
    None => handle.cwd
  }
  let mcp_servers = match existing {
    Some({ mcp_servers, .. }) =>
      if mcp_servers.is_empty() {
        fresh_mcp_names
      } else {
        mcp_servers
      }
    None => fresh_mcp_names
  }
  let effort_json = match handle.router.active_effort() {
    Some(value) => Json::string(value)
    None => Json::null()
  }
  let json = Json::object(
    Map::from_array([
      ("cwd", Json::string(cwd)),
      ("model", Json::string(handle.router.active_slot_id())),
      ("effort", effort_json),
      ("mcp_servers", Json::array(mcp_servers.map(name => Json::string(name)))),
    ]),
  )
  // The bucket may not exist yet (a fresh session/new precedes any history
  // save); the sidecar must not depend on write ordering.
  self.fs.mkdir(handle.project_dir, recursive=true) catch {
    _ => ()
  }
  self.fs.write_file_atomic(path, json.stringify(indent=2) + "\n") catch {
    _ =>
      acp_warn(
        "cetas-acp: session sidecar write failed (session=" + session_id + ")\n",
      )
  }
  acp_persist_mutex.release()
}

///|
/// `session/set_config_option` plus the sidecar refresh the config file cannot
/// own (model/effort must reach the next load/resume); `permission` never writes.
pub async fn CetasAcpHost::handle_set_config_option_sidecar(
  self : CetasAcpHost,
  context : @acp.AgentContext,
  params : @acp.SetSessionConfigOptionParams,
) -> @acp.SetSessionConfigOptionResult raise @acp.HandlerError {
  if self.sessions.contains(params.session_id) {
    self.debug_wire_in(
      session_id=params.session_id,
      rpc_method="session/set_config_option",
      params=debug_config_option_params(params),
    )
  }
  let context = self.debug_tap_context(context)
  let result = self.handle_set_config_option(context, params)
  if params.config_id == "model" || params.config_id == "effort" {
    match self.sessions.get(params.session_id) {
      Some(handle) => self.update_session_sidecar(params.session_id, handle, [])
      None => ()
    }
  }
  result
}

// --------------------------------------------------------- load / resume / list

///|
/// The project bucket holding a session's persisted state, after validating
/// the id shape: invalid shapes reject invalid params, and an id with
/// neither history nor sidecar in any candidate bucket is unknown. The
/// client cwd's bucket (when given) is searched first — a reconnecting
/// client names the workspace it expects the session in.
async fn CetasAcpHost::require_session_bucket(
  self : CetasAcpHost,
  session_id : String,
  client_cwd? : String = "",
) -> String raise @acp.HandlerError {
  match @fs_session.validate_session_id(session_id) {
    Err(reason) =>
      raise @acp.HandlerError::InvalidParams(
        message="cetas-acp: invalid session id: " + reason,
      )
    Ok(_) => ()
  }
  for dir in self.candidate_project_dirs(client_cwd~) {
    let has_history = self.fs.exists(
      @fs_session.jsonl_session_path(dir, session_id),
    ) catch {
      _ => false
    }
    if has_history {
      return dir
    }
    let has_sidecar = match host_sidecar_path(dir, session_id) {
      Some(path) => self.fs.exists(path) catch { _ => false }
      None => false
    }
    if has_sidecar {
      return dir
    }
  }
  raise @acp.HandlerError::InvalidParams(
    message="cetas-acp: unknown session '" + session_id + "'",
  )
}

///|
/// Rebuild one persisted session as live: retire a same-id live session first
/// (one id never backs two agents); cwd resolves client_cwd > sidecar >
/// platform fallback; the client's MCP set wins verbatim (empty set with a
/// recorded roster only warns — only names were persisted). Sidecar
/// model/effort restore is best-effort; rebuilt sessions start `default`.
/// `origin_bucket` is the source session's project bucket (the fork parent
/// or the load target); a live same-id origin carries its own.
async fn CetasAcpHost::restore_session(
  self : CetasAcpHost,
  context : @acp.AgentContext,
  session_id : String,
  client_cwd : String,
  client_mcp : Array[@acp.McpServer],
  sidecar_of? : String,
  origin_bucket? : String = "",
) -> SessionHandle raise @acp.HandlerError {
  let origin = match sidecar_of {
    Some(id) => id
    None => session_id
  }
  match self.sessions.get(session_id) {
    Some(handle) => self.retire_live_session(session_id, handle)
    None => ()
  }
  let origin_dir = if origin_bucket.length() > 0 {
    origin_bucket
  } else {
    match self.sessions.get(origin) {
      Some(live) => live.project_dir
      None => ""
    }
  }
  let sidecar = if origin_dir.length() > 0 {
    read_session_sidecar(self.fs, project_dir=origin_dir, session_id=origin)
  } else {
    None
  }
  let cwd = if client_cwd.length() > 0 {
    client_cwd
  } else {
    match sidecar {
      Some({ cwd, .. }) => cwd
      None => ""
    }
  }
  if client_mcp.is_empty() {
    match sidecar {
      Some({ mcp_servers, .. }) =>
        if !mcp_servers.is_empty() {
          let roster = StringBuilder()
          roster.write_string(mcp_servers[0])
          for i = 1; i < mcp_servers.length(); i = i + 1 {
            roster.write_string(", ")
            roster.write_string(mcp_servers[i])
          }
          acp_warn(
            "cetas-acp: session " +
            origin +
            " previously had MCP servers [" +
            roster.to_string() +
            "]; the client sent none, they are not reconnected\n",
          )
        }
      None => ()
    }
  }
  let spawned : Result[SessionHandle, String] = (self.spawn_session)(
    session_id,
    {
      cwd,
      additional_directories: Omitted,
      mcp_servers: client_mcp,
      meta: Omitted,
    },
  ) catch {
    error => Err(error.to_string())
  }
  let handle = match spawned {
    Ok(handle) => handle
    Err(message) =>
      raise @acp.HandlerError::Application(
        message="cetas-acp: session restore failed: " + message,
      )
  }
  match sidecar {
    Some({ model, effort, .. }) => {
      if model.length() > 0 {
        if handle.router.list_slot_ids().contains(model) {
          handle.router.switch_slot(model) catch {
            error =>
              acp_warn(
                "cetas-acp: sidecar model '" +
                model +
                "' failed to restore (session=" +
                origin +
                "): " +
                error.to_string() +
                "\n",
              )
          }
        } else {
          acp_warn(
            "cetas-acp: sidecar model '" +
            model +
            "' is not in the session's slots (session=" +
            origin +
            "); keeping the default\n",
          )
        }
      }
      match effort {
        Some(value) =>
          handle.router.select_effort(handle.router.active_slot_id(), value) catch {
            _ =>
              acp_warn(
                "cetas-acp: sidecar effort '" +
                value +
                "' is not advertised by the restored slot (session=" +
                origin +
                "); keeping the slot default\n",
              )
          }
        None => ()
      }
    }
    None => ()
  }
  handle.plan.set_session_name(session_id)
  set_handle_context(handle, context)
  // Bound now so load/resume pushes (session_info_update) reach the client
  // before the first prompt attaches the bridge again (idempotent re-attach).
  handle.bridge.attach(context~, session_id~)
  self.sessions[session_id] = handle
  handle
}

///|
async fn replay_push_chunk(
  context : @acp.AgentContext,
  session_id : String,
  wrap : (@acp.ContentChunk) -> @acp.SessionUpdate,
  text : String,
) -> Unit noraise {
  context.session_update({
    session_id,
    update: wrap({
      content: Text({ annotations: Omitted, text, meta: Omitted, }),
      message_id: Omitted,
      meta: Omitted,
    }),
    meta: Omitted,
  }) catch {
    _ =>
      acp_warn(
        "cetas-acp: history replay push failed (session=" + session_id + ")\n",
      )
  }
}

///|
/// Replay one persisted session's history as `session/update` chunks, straight
/// through the invocation's context (not the bridge queue — replay must reach
/// the client even though no turn is running): user → `user_message_chunk`,
/// assistant → `agent_thought_chunk` (when persisted) + `agent_message_chunk`s;
/// tool rounds have no faithful replay. The store is the session's own
/// project store.
async fn replay_session_history(
  context : @acp.AgentContext,
  session_id : String,
  store~ : @fs_session.JsonlSessionStore,
) -> Unit noraise {
  let loaded : Result[@posoco.Session, Error] = Ok(store.load(session_id)) catch {
    error => Err(error)
  }
  match loaded {
    Err(error) =>
      acp_warn(
        "cetas-acp: history replay skipped (session=" +
        session_id +
        "): " +
        error.to_string() +
        "\n",
      )
    Ok(session) =>
      for message in session.messages {
        match message {
          UserMessage(content~) =>
            for block in content {
              match block {
                Text(text) =>
                  replay_push_chunk(
                    context,
                    session_id,
                    chunk => UserMessageChunk(chunk),
                    text,
                  )
                _ => ()
              }
            }
          AssistantMessage(content~, reasoning~, ..) => {
            match reasoning {
              Some(thought) =>
                if thought.content.length() > 0 {
                  replay_push_chunk(
                    context,
                    session_id,
                    chunk => AgentThoughtChunk(chunk),
                    thought.content,
                  )
                }
              None => ()
            }
            for block in content {
              match block {
                Text(text) =>
                  replay_push_chunk(
                    context,
                    session_id,
                    chunk => AgentMessageChunk(chunk),
                    text,
                  )
                _ => ()
              }
            }
          }
          _ => ()
        }
      }
  }
}

///|
/// `session/load`: rebuild and replay. The SDK expects the replay after the
/// result is accepted; the codec has no post-acceptance seam, so chunks
/// stream through the invocation's context before answering.
pub async fn CetasAcpHost::handle_load_session(
  self : CetasAcpHost,
  context : @acp.AgentContext,
  params : @acp.LoadSessionParams,
) -> @acp.LoadSessionResult raise @acp.HandlerError {
  let bucket = self.require_session_bucket(
    params.session_id,
    client_cwd=params.cwd,
  )
  self.debug_wire_in(
    session_id=params.session_id,
    rpc_method="session/load",
    params=debug_restore_params(session_id=params.session_id, cwd=params.cwd),
  )
  let context = self.debug_tap_context(context)
  let handle = self.restore_session(
    context,
    params.session_id,
    params.cwd,
    params.mcp_servers,
    origin_bucket=bucket,
  )
  replay_session_history(context, params.session_id, store=handle.store)
  // The reconnecting client labels the session from this push immediately.
  push_session_title(params.session_id, handle, only_unnamed=false)
  {
    modes: Value(acp_modes_block(acp_mode_id_of(handle.plan))),
    config_options: Value(
      build_config_options(handle.router, handle.permission.mode),
    ),
    meta: Omitted,
  }
}

///|
/// `session/resume`: rebuild without replaying — the client already holds the history.
pub async fn CetasAcpHost::handle_resume_session(
  self : CetasAcpHost,
  context : @acp.AgentContext,
  params : @acp.ResumeSessionParams,
) -> @acp.ResumeSessionResult raise @acp.HandlerError {
  let bucket = self.require_session_bucket(
    params.session_id,
    client_cwd=params.cwd,
  )
  let client_mcp : Array[@acp.McpServer] = match params.mcp_servers {
    Value(servers) => servers
    _ => []
  }
  self.debug_wire_in(
    session_id=params.session_id,
    rpc_method="session/resume",
    params=debug_restore_params(session_id=params.session_id, cwd=params.cwd),
  )
  let context = self.debug_tap_context(context)
  let handle = self.restore_session(
    context,
    params.session_id,
    params.cwd,
    client_mcp,
    origin_bucket=bucket,
  )
  push_session_title(params.session_id, handle, only_unnamed=false)
  {
    modes: Value(acp_modes_block(acp_mode_id_of(handle.plan))),
    config_options: Value(
      build_config_options(handle.router, handle.permission.mode),
    ),
    meta: Omitted,
  }
}

///|
/// `session/fork`: the parent is untouched; the child gets a new durable id,
/// a copy of the parent's committed history, its own machinery and sidecar —
/// immediately promptable. Existence follows the load posture, live checked
/// first (a session whose sidecar write failed and has not turned is still
/// forkable); cwd and MCP mirror load.
pub async fn CetasAcpHost::handle_fork_session(
  self : CetasAcpHost,
  context : @acp.AgentContext,
  params : @acp.ForkSessionParams,
) -> @acp.ForkSessionResult raise @acp.HandlerError {
  // The parent's bucket: a live parent carries its own; a closed parent
  // resolves through the candidate buckets (the fork cwd is the child's,
  // not the parent's, so it cannot scope this lookup).
  let parent_dir = match self.sessions.get(params.session_id) {
    Some(handle) => handle.project_dir
    None => self.require_session_bucket(params.session_id)
  }
  self.debug_wire_in(
    session_id=params.session_id,
    rpc_method="session/fork",
    params=debug_session_params(params.session_id),
  )
  let parent_sidecar = read_session_sidecar(
    self.fs,
    project_dir=parent_dir,
    session_id=params.session_id,
  )
  let client_mcp : Array[@acp.McpServer] = match params.mcp_servers {
    Value(servers) => servers
    _ => []
  }
  let child_id = mint_session_id()
  // History source: the parent's own bucket store reads from disk, so a live
  // parent forks its last committed state. A read failure fails the fork; an
  // empty history is legal (no save).
  let parent_store = @fs_session.JsonlSessionStore(parent_dir)
  let loaded : Result[@posoco.Session, Error] = Ok(
    parent_store.load(params.session_id),
  ) catch {
    error => Err(error)
  }
  let parent_session = match loaded {
    Ok(session) => session
    Err(error) =>
      raise @acp.HandlerError::Application(
        message="cetas-acp: fork history read failed (session=" +
          params.session_id +
          "): " +
          error.to_string(),
      )
  }
  // The child assembles like a load: parent sidecar facts + the fork's cwd
  // override. The spawn assigns the child's project store.
  let context = self.debug_tap_context(context)
  let handle = self.restore_session(
    context,
    child_id,
    params.cwd,
    client_mcp,
    sidecar_of=params.session_id,
    origin_bucket=parent_dir,
  )
  // History copy lands in the child's own store before the fork answers —
  // the child must prompt against its parent's committed state. A failed
  // copy retires the freshly spawned child.
  if parent_session.messages.length() > 0 {
    let saved : Result[Unit, Error] = Ok(
      handle.store.save(child_id, parent_session),
    ) catch {
      error => Err(error)
    }
    match saved {
      Ok(_) => ()
      Err(error) => {
        self.retire_live_session(child_id, handle)
        raise @acp.HandlerError::Application(
          message="cetas-acp: fork history write failed (session=" +
            child_id +
            "): " +
            error.to_string(),
        )
      }
    }
  }
  // Child sidecar: parent's roster carries over unless the fork injected its own set.
  let fresh_roster : Array[String] = if client_mcp.is_empty() {
    match parent_sidecar {
      Some({ mcp_servers, .. }) => mcp_servers
      None => []
    }
  } else {
    client_mcp.map(server => acp_mcp_server_name(server))
  }
  self.update_session_sidecar(child_id, handle, fresh_roster)
  {
    session_id: child_id,
    modes: Value(acp_modes_block(acp_mode_id_of(handle.plan))),
    config_options: Value(
      build_config_options(handle.router, handle.permission.mode),
    ),
    meta: Omitted,
  }
}

///|
fn CetasAcpHost::snapshot_sessions(
  self : CetasAcpHost,
) -> Array[(String, SessionHandle)] {
  let snapshot : Array[(String, SessionHandle)] = []
  for pair in self.sessions {
    snapshot.push(pair)
  }
  snapshot
}

///|
/// Lazily refresh every refreshable provider's model list after startup:
/// refresh → persist to the model cache → swap the catalog in the shared
/// platform list → hot-swap live routers → push `config_option_update` per
/// live session. Per-provider failures only warn; cached slots keep standing.
pub async fn CetasAcpHost::refresh_model_lists(
  self : CetasAcpHost,
) -> Unit noraise {
  let landed : Array[(String, @llm.ProviderModelCatalog)] = []
  for factory in self.refreshables {
    let provider_id = factory.provider_id()
    let outcome : Result[@llm.ProviderModelCatalog?, Error] = Ok(
      @cetas_core.refresh_provider_catalog(factory, self.refresh_snapshot),
    ) catch {
      error => Err(error)
    }
    match outcome {
      Err(error) =>
        if @async.is_cancellation_error(error) {
          // Shutdown cancelled the refresh task; stop silently.
          return
        } else {
          acp_warn(
            "cetas-acp: model list refresh failed for provider " +
            provider_id +
            ": " +
            error.to_string() +
            "\n",
          )
        }
      Ok(None) => ()
      Ok(Some(catalog)) => {
        @cetas_core.write_model_list_cache(
          self.fs,
          home=self.home,
          provider_id,
          @cetas_core.catalog_model_records(catalog),
        ) catch {
          _ =>
            acp_warn(
              "cetas-acp: model cache write failed for provider " +
              provider_id +
              "\n",
            )
        }
        swap_platform_catalog(self.catalogs, provider_id, catalog)
        landed.push((provider_id, catalog))
      }
    }
  }
  if landed.is_empty() {
    return
  }
  for pair in self.snapshot_sessions() {
    let (_session_id, handle) = pair
    for landed_pair in landed {
      let (provider_id, catalog) = landed_pair
      let swapped : Result[Unit, Error] = try {
        handle.router.replace_provider_slots(provider_id, catalog.slots())
        Ok(())
      } catch {
        error => Err(error)
      }
      match swapped {
        Ok(_) => ()
        Err(error) =>
          acp_warn(
            "cetas-acp: router slot replacement failed for provider " +
            provider_id +
            ": " +
            error.to_string() +
            "\n",
          )
      }
    }
  }
  self.push_config_option_update()
}

///|
/// Push each live session's current configOptions as `config_option_update`
/// after a background refresh; best-effort, a failing push only warns.
async fn CetasAcpHost::push_config_option_update(
  self : CetasAcpHost,
) -> Unit noraise {
  for pair in self.snapshot_sessions() {
    let (session_id, handle) = pair
    match handle.context {
      Some(context) =>
        context.session_update({
          session_id,
          update: @acp.SessionUpdate::ConfigOptionUpdate({
            config_options: build_config_options(
              handle.router,
              handle.permission.mode,
            ),
            meta: Omitted,
          }),
          meta: Omitted,
        }) catch {
          _ =>
            acp_warn(
              "cetas-acp: config_option_update push failed (session=" +
              session_id +
              ")\n",
            )
        }
      None => ()
    }
  }
}

///|
/// The active model slot's provider-declared context window, or `None` when
/// the slot does not declare one. The bridge stamps it onto
/// `UsageUpdate.size`; cetas has no `AgentConfig.model_context_window`
/// source to prefer (default_agent_config passes nothing).
fn active_slot_context_window(router : @llm.RouterModelPort) -> Int? {
  let active = router.active_slot_id()
  for slot in router.list_slots() {
    if slot.id == active {
      return slot.context_window
    }
  }
  None
}

///|
/// Union the session's MCP sources onto one bridge: the discover-produced
/// registration (mcp.json locals in `pending`/`configs`) plus the
/// `params.mcp_servers` declarations. Injection wins conflicts — a local
/// server leaves `pending` and `configs` (a reconnect can never resurrect it)
/// when it shares its name with an injected server or dials the same endpoint
/// (`same_server`), with one warning per shadowed server. Every mapped
/// injected config then registers exactly as discover does: `pending` feeds
/// activate, `configs` stays reconnectable.
async fn union_mcp_servers(
  bridge : @mcp.MCPToolBridge,
  servers : Array[@acp.McpServer],
) -> Unit noraise {
  let injected : Array[@mcp.MCPServerConfig] = []
  for server in servers {
    let name = @devkit.sanitize_label(acp_mcp_server_name(server))
    for index in acp_invalid_headers(server) {
      acp_warn(
        "cetas-acp: MCP server '" +
        name +
        "': http header at index " +
        index.to_string() +
        " has an empty name and was skipped\n",
      )
    }
    match acp_mcp_to_config(server) {
      Ok(config) => injected.push(config)
      Err(message) => acp_warn("cetas-acp: " + message + "\n")
    }
  }
  // Backward so an in-place removal never skips the next local.
  for i = bridge.pending.length() - 1; i >= 0; i = i - 1 {
    let disk = bridge.pending[i]
    let mut shadowed = false
    for config in injected {
      if config.name == disk.name || same_server(config, disk) {
        shadowed = true
        break
      }
    }
    if shadowed {
      acp_warn(
        "cetas-acp: local mcp server '" +
        @devkit.sanitize_label(disk.name) +
        "' shadowed by injected\n",
      )
      ignore(bridge.pending.remove(i))
      ignore(bridge.configs.remove(disk.name))
    }
  }
  for config in injected {
    bridge.pending.push(config)
    bridge.configs[config.name] = config
  }
}

// ----------------------------------------------------------- process platform

///|
/// Process-level assembly shared by every session of one host process; built
/// once per process, the catalogs array is swapped in place by the lazy
/// refresh.
priv struct Platform {
  home : String
  cwd : String
  fs : &@workspace.WorkspaceFs
  catalogs : Array[@llm.ProviderModelCatalog]
  default_slot_id : String
  /// Persisted reasoning effort restored onto every session's router.
  persisted_effort : String?
  /// Startup tool-approval posture, resolved at assembly and stamped on
  /// every session; never persisted.
  permission_mode : @permission.PermissionMode
  credential_store : @credentials.FileProviderCredentialStore
  session_store : @fs_session.JsonlSessionStore
  refreshables : Array[&@llm.RefreshableProviderFactory]
  refresh_snapshot : @cetas_core.ProviderCredentialSnapshot
  /// The host's process task group (nmem flusher, MCP monitors);
  /// `None` in tests without a group.
  mcp_group : @async.TaskGroup[Unit]?
  /// The MCP discovery load mode every session's bridge discovers under.
  mcp_mode : @mcp.LoadMode
  /// The `CETAS_DELEGATE_FS` resolution stamped at assembly.
  delegation : DelegateFsMode
  /// The `CETAS_DEBUG_*` taps stamped at assembly.
  debug : DebugTaps
}

///|
/// Swap one provider's catalog in the shared platform list so sessions minted
/// after a refresh compose from it; an empty list (tests) is left alone.
fn swap_platform_catalog(
  catalogs : Array[@llm.ProviderModelCatalog],
  provider_id : String,
  catalog : @llm.ProviderModelCatalog,
) -> Unit {
  if catalogs.is_empty() {
    return
  }
  for i in 0..<catalogs.length() {
    if catalogs[i].provider_id == provider_id {
      catalogs[i] = catalog
      return
    }
  }
  catalogs.push(catalog)
}

///|
/// Assemble the process platform once: settings → factories → credentials →
/// model cache → catalogs → persisted selection; fails loudly with no
/// provider configured. The persisted selection resolves here (drifted
/// slot/stale effort degrades with one warning); the model-list disk cache
/// seeds a restart's announcements without network. `delegation`/`debug`
/// default to the static test posture; production passes the env resolutions.
async fn build_platform(
  home~ : String,
  cwd~ : String,
  fs : &@workspace.WorkspaceFs,
  mcp_group~ : @async.TaskGroup[Unit]?,
  mcp_mode~ : @mcp.LoadMode,
  delegation? : DelegateFsMode = DelegateFsMode::Local,
  debug? : DebugTaps = { catalog: false, wire: false, },
) -> Platform raise @posoco.CompositionError {
  let settings = @cetas_core.load_provider_settings(fs, home~)
  let ext_ctx = @devkit.ExtContext::default()
  let factories = @cetas_core.all_provider_factories(ext_ctx, settings)
  @cetas_core.validate_provider_settings(settings, factories)
  let store = @credentials.FileProviderCredentialStore(
    fs,
    @cetas_core.credentials_path(home),
  )
  let snapshot = read_credential_snapshot(store, factories, settings~)
  let model_cache = match @cetas_core.read_model_list_cache(fs, home~) {
    Ok(entries) => entries
    Err(message) => {
      acp_warn(
        "cetas-acp: model list cache unreadable (" +
        message +
        "); announcing static catalogs until the first refresh lands\n",
      )
      Map::from_array([])
    }
  }
  let catalogs : Array[@llm.ProviderModelCatalog] = []
  for factory in factories {
    let provider_id = factory.provider_id()
    let cached = model_cache.get(provider_id)
    match
      @cetas_core.try_build_provider_catalog(
        factory,
        snapshot,
        cached_models=cached,
      ) {
      Ok(Some(catalog)) => catalogs.push(catalog)
      Ok(None) => ()
      Err(err) =>
        // One misconfigured provider must not take down the whole host.
        acp_warn(
          "cetas-acp: provider " +
          provider_id +
          " skipped: " +
          err.to_string() +
          "\n",
        )
    }
  }
  if catalogs.is_empty() {
    raise @posoco.CompositionError::EmptyPort(
      "cetas-acp.providers: no configured model provider — configure one in ~/.cetas/settings.json or log in via cetas first",
    )
  }
  // No OAuth surface in a headless/stdio process; token refresh works for
  // on-disk credentials.
  let selection = @cetas_core.read_active_model_selection(fs, home~)
  let default_slot_id = @cetas_core.resolve_default_slot_id(catalogs, selection)
  match selection {
    Some({ slot, .. }) =>
      if default_slot_id == "" {
        acp_warn(
          "cetas-acp: persisted model slot '" +
          slot +
          "' is no longer configured; using the first catalog slot (stale entry kept in ~/.cetas/settings.json)\n",
        )
      }
    None => ()
  }
  let persisted_effort = match selection {
    Some({ effort: Some(effort), .. }) => Some(effort)
    _ => None
  }
  let session_store = @fs_session.JsonlSessionStore(
    @cetas_core.sessions_dir(home),
  )
  let permission_mode = startup_permission_mode()
  // `device_id` stays empty: no host crypto surface in stdio; providers mint a local id.
  let refreshables = @cetas_core.refreshable_factories(ext_ctx)
  {
    home,
    cwd,
    fs,
    catalogs,
    default_slot_id,
    persisted_effort,
    permission_mode,
    credential_store: store,
    session_store,
    refreshables,
    refresh_snapshot: snapshot,
    mcp_group,
    mcp_mode,
    delegation,
    debug,
  }
}

///|
/// Read every provider's credential once; missing/unconfigured providers map to no entry.
async fn read_credential_snapshot(
  store : @credentials.FileProviderCredentialStore,
  factories : Array[&@llm.ProviderFactory],
  settings~ : Map[String, Json],
) -> @cetas_core.ProviderCredentialSnapshot raise @posoco.CompositionError {
  let credentials : Map[String, @oauth.ProviderCredential] = Map::from_array([])
  for factory in factories {
    let provider_id = factory.provider_id()
    let credential = store.read(provider_id) catch {
      err =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="cetas-acp.credentials",
          detail=@cetas_core.oauth_error_text(err),
        )
    }
    match credential {
      Some(value) => credentials[provider_id] = value
      None => ()
    }
  }
  @cetas_core.ProviderCredentialSnapshot::ProviderCredentialSnapshot(
    settings~,
    credentials~,
  )
}

///|
/// The CETAS_GOAL seam: a non-empty condition arms the goal runner; unset
/// or blank degrades to no goal ext.
fn goal_ext_from_env(value : String?) -> @goal.GoalRunner? {
  match value {
    Some(condition) if condition.trim().length() > 0 =>
      Some(@goal.goal_extension(goal_condition=condition))
    _ => None
  }
}

///|
/// Assemble one session's machinery over the shared platform: the product
/// pieces compose here in product order exactly as every cetas host composes
/// them, and this adapter wires only the ACP protocol surface around them —
/// the session-lifetime bridge (approval source, UI port, context window),
/// plan review, the fs-delegate shell, MCP discovery/union, the personal
/// zcode opt-in, and the host profile prompt section. `session_store` is the
/// session's project store (production resolves it per cwd; the platform's
/// default store stands in for direct assembly callers).
async fn build_session_agent(
  platform~ : Platform,
  cwd~ : String,
  session_id? : String = "",
  session_store? : @fs_session.JsonlSessionStore = platform.session_store,
  mcp_servers? : Array[@acp.McpServer] = [],
  host_kind? : HostKind = HostKind::Generic,
) -> SessionHandle raise @posoco.CompositionError {
  // The router is built first so the bridge can stamp the active slot's
  // context window; the assembly reuses it instead of minting another.
  let router = @llm.RouterModelPort::from_catalogs(
    platform.catalogs,
    default_slot_id=platform.default_slot_id,
    provider_credential_store=Some(
      platform.credential_store as &@oauth.ProviderCredentialStore,
    ),
  )
  match platform.persisted_effort {
    Some(effort) =>
      if platform.default_slot_id != "" {
        router.select_effort(platform.default_slot_id, effort) catch {
          _ =>
            acp_warn(
              "cetas-acp: persisted reasoning effort '" +
              effort +
              "' is not advertised by model slot '" +
              platform.default_slot_id +
              "'; using the slot's default effort\n",
            )
        }
      }
    None => ()
  }
  let bridge = @ext_acp.AcpBridge(
    context_window=active_slot_context_window(router),
  )
  // Context files (AGENTS.md/CLAUDE.md) are best-effort: a read failure
  // never blocks composition.
  let loader = @context.ContextLoader(platform.fs, home=platform.home)
  let bundle = loader.load(cwd) catch { _ => @context.ContextBundle::empty() }
  let context_contributor = @context.ContextPromptContributor(
    bundle~,
    ns="cetas",
  )
  let cetas = @cetas_core.Cetas(
    context_contributor=Some(
      context_contributor as &@posoco.SystemPromptContributor,
    ),
  )
  // Session-private so plan/permission facts never leak into another's hooks.
  let event_bus = @devkit.EventBus()
  // `CETAS_DELEGATE_FS=host`: the tool-facing fs is a delegate shell; the
  // host stamps the invocation context at every attach point, so until the
  // first prompt (and after retirement) reads/writes stay local.
  let mut fs_delegate : AcpDelegateFs? = None
  let session_fs : &@workspace.WorkspaceFs = match platform.delegation {
    DelegateFsMode::Host => {
      let delegate = AcpDelegateFs::AcpDelegateFs(
        local_fs=platform.fs,
        session_id~,
      )
      fs_delegate = Some(delegate)
      delegate as &@workspace.WorkspaceFs
    }
    DelegateFsMode::Local => platform.fs
  }
  // The bridge is the policy's approval source (asks become
  // session/request_permission renders) and ask_question's UI (each ask
  // maps onto an ACP elicitation form). nmem registers because acp builds
  // as a personal flavor — the compile-time constant is the only gate.
  let permission_policy = @permission.PermissionPolicy(
    platform.permission_mode,
    approval=Some(bridge as &@permission.ApprovalSource),
    bus=Some(event_bus),
  )
  // Plan mode's enter/exit tools bypass the permission ask — their decision
  // is the plan review, not a tool-permission prompt. It must be built
  // after the policy above: its constructor publishes the tool exemptions
  // on the shared bus and only a subscribed gate receives them.
  let plan_mode = @plan.PlanMode(
    config={
      ..@plan.PlanModeConfig::default()
      // ask_question rides the permission read class.
      ,
      allowed_tools: ["read", "glob", "grep", "ask_question"],
      allow_model_entry: true,
    },
    review=Some(AcpPlanReview::{ bridge, } as &@plan.PlanReviewSource),
    bus=Some(event_bus),
    fs=Some(platform.fs),
  )
  // Personal host holds goal: the condition arrives via CETAS_GOAL; no
  // driver loop this round, so regular turns are unaffected.
  let goal = goal_ext_from_env(read_env_var("CETAS_GOAL"))
  let exts : Array[&@posoco.Extension] = [
    cetas,
    router as &@posoco.Extension,
    session_store as &@posoco.Extension,
    bridge as &@posoco.Extension,
    permission_policy,
    plan_mode,
  ]
  match goal {
    Some(runner) => exts.push(runner as &@posoco.Extension)
    None => ()
  }
  // Records quota verdicts per session and re-runs the interrupted session
  // at the provider-stated reset time; one guard per session agent.
  let ratelimit = @ratelimit.RateLimitGuard()
  exts.push(ratelimit as &@posoco.Extension)
  for
    tool in @cetas_core.build_default_features(
      ctx={ fs: session_fs, cwd, home: platform.home, },
      ui=Some(bridge as &@posoco.UiPort),
      nmem_group=platform.mcp_group,
    ) {
    exts.push(tool)
  }
  // Personal host opt-in: zcode delegation registers when detected, degrades to absent otherwise.
  let zcode_ext = @zcode.zcode_ext_if_detected(
    env=fn(key : String) { read_env_var(key) },
    exists=async fn(path : String) -> Bool {
      session_fs.exists(path) catch {
        _ => false
      }
    },
  ) catch {
    _ => None
  }
  match zcode_ext {
    Some(ext) => exts.push(ext as &@posoco.Extension)
    None => ()
  }
  // The routing table and catalog base are captured BEFORE the MCP bridge
  // joins: the bridge's decorator source appends its own live tools, so
  // including them here would duplicate every name.
  let routing : Map[String, &@posoco.ToolProvider] = Map::from_array([])
  let base_defs : Array[@posoco.ToolDef] = []
  for ext in exts {
    for provider in ext.manifest().tools {
      for def in provider.list_tools() {
        routing[def.name.to_string()] = provider
        base_defs.push(def)
      }
    }
  }
  let config = @cetas_core.default_agent_config(
    system_prompt=Some(compose_system_prompt(host_kind, cwd~)),
  )
  // One bridge per session so each session's server set/catalog stay private.
  // The sources union: mcp.json discovery always runs over the session cwd,
  // and the params-injected declarations merge onto the same bridge —
  // injected wins when the two sources conflict.
  let mcp_bridge = match
    @mcp.MCPToolBridge::discover(
      cwd~,
      user_mcp_json=@cetas_core.mcp_config_path(platform.home),
      mode=platform.mcp_mode,
    ) {
    Ok(discovered) => {
      union_mcp_servers(discovered, mcp_servers)
      discovered
    }
    Err(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-acp.mcp",
        detail=message,
      )
  }
  match platform.mcp_group {
    Some(group) => mcp_bridge.attach(group)
    None => ()
  }
  // Always when params inject servers: their connect happens at session/new
  // even under Lazy (the bridge keeps the discovery mode, whose on_start
  // activation would only be guaranteed for the locals). A raise here is
  // degenerate async machinery; per-server failures only warn.
  if platform.mcp_mode is @mcp.LoadMode::Eager || !mcp_servers.is_empty() {
    let failures = mcp_bridge.activate() catch { _ => [] }
    for pair in failures {
      let (server, reason) = pair
      acp_warn(
        "cetas-acp: MCP server '" +
        server +
        "' failed to connect: " +
        reason +
        "\n",
      )
    }
  }
  // Lazy activation changes the tool set mid-life, so the catalog is owned
  // by the runtime-seam source; MCP execution routes through the decorator.
  let base_runtime = @runtime.PortRuntime(
    model=router as &@posoco.ModelPort,
    tools=routing,
  )
  let runtime = @mcp.McpRuntime(
    bridge=mcp_bridge,
    fallback=base_runtime as &@runtime.Runtime,
  )
  let catalog_source = @mcp.McpCatalogSource(
    bridge=mcp_bridge,
    base_tools=base_defs,
  )
  exts.push(mcp_bridge as &@posoco.Extension)
  let agent = @posoco.Agent::with_runtime(
    exts~,
    config~,
    runtime=runtime as &@runtime.Runtime,
    catalog_source=catalog_source as &@runtime.CatalogSource,
  )
  // The guard re-runs turns itself, so it needs the composed agent.
  ratelimit.bind(agent)
  // The monitor dies with the host group at stdin EOF.
  match platform.mcp_group {
    Some(group) => ratelimit.spawn_monitor(group)
    None => ()
  }
  // After activation, dump the full session catalog (bridge cache + base_defs).
  if platform.debug.catalog && session_id.length() > 0 {
    debug_dump_catalog(
      platform.fs,
      home=platform.home,
      session_id~,
      host_kind~,
      injected=!mcp_servers.is_empty(),
      mcp_tools=(mcp_bridge as &@posoco.ToolProvider).list_tools(),
      base_tools=base_defs,
    )
  }
  {
    bridge,
    router,
    agent,
    cwd,
    store: session_store,
    project_dir: session_store.root_dir,
    plan: plan_mode,
    permission: permission_policy,
    fs_delegate,
    context: None,
    in_flight: None,
    turn_lock: @async.Mutex::Mutex(),
    last_mode_id: ACP_MODE_DEFAULT_ID,
  }
}
