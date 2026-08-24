///|
/// CetasAcpHost — the ACP host state for one cetas agent process.
///
/// Owns the composed Posoco `Agent` plus the `AcpBridge` that projects turn
/// events onto ACP session updates and gates tools through ACP permission
/// requests. The ACP endpoint, framing, and stdio runtime belong to
/// `colmugx/acp`; this host only supplies the typed handlers:
///
/// - `session/new` mints one ACP session id and uses the same id as the
///   Posoco session id (the stores accept unknown ids as fresh sessions).
/// - `session/prompt` attaches the invocation's `AgentContext`, runs a
///   concurrent update pump for real-time streaming, drives
///   `Agent::run_turn`, flushes, closes the pump scope, and answers with the
///   bridge-derived stop reason.
/// - `session/cancel` cancels the session's in-flight turn task; the prompt
///   request then settles with `stopReason: cancelled`.
///
/// v1 scope: one process serves one working directory (launch cetas-acp
/// from the project root — Zed does this). `session/new` acknowledges
/// `cwd` but tools run in the process working directory.
///
/// Model/effort selection is process-global: one Agent owns one router, so
/// `session/set_config_option` on any session retunes every session (v1:
/// the last selection wins) and is persisted to `~/.cetas/settings.json`
/// for the next launch.

///|
/// ACP session ids double as Posoco session ids, so no id mapping table
/// exists. One counter covers the process lifetime.
pub struct CetasAcpHost {
  agent : @posoco.Agent
  bridge : @ext_acp.AcpBridge
  version : String
  router : @llm.RouterModelPort
  /// Cetas home (`~/.cetas`), where the selection is persisted.
  home : String
  /// The fs the selection is read/written through; the same instance the
  /// assembly used, so tests can substitute a fake.
  fs : &@workspace.WorkspaceFs
  /// Live sessions' outbound contexts, captured at `session/new` so the
  /// background model refresh can push `config_option_update` frames to
  /// editors without waiting for the next request.
  contexts : Map[String, @acp.AgentContext]
  /// Refreshable provider seams plus the snapshot they refresh against —
  /// the pieces `refresh_model_lists` needs, captured at assembly. Embedding
  /// and test constructors may substitute fakes via `CetasAcpHost::of`.
  refreshables : Array[&@llm.RefreshableProviderFactory]
  refresh_snapshot : @cetas_core.ProviderCredentialSnapshot
  mut session_counter : Int
  /// In-flight turn task per session, so `session/cancel` can interrupt it.
  in_flight : Map[String, @async.Task[@posoco.TurnResult]]
}

///|
/// Compose the production host: native agent assembly (providers from
/// `~/.cetas/settings.json` + credentials, JSONL session store under
/// `~/.cetas/sessions`, context files, plan mode, the default cetas tool
/// set, MCP servers from mcp.json) plus the ACP bridge. Fails loudly when
/// no model provider is configured — an ACP agent without a model cannot
/// serve any prompt.
///
/// `mcp_group` is the host's long-lived task group; stdio MCP servers spawn
/// their child processes on it, so it must outlive the agent. `mcp_mode`
/// selects when mcp.json servers connect: `Lazy` (default) at the first
/// turn's lifecycle start, `Eager` right here at composition.
pub async fn CetasAcpHost::CetasAcpHost(
  home~ : String,
  cwd~ : String,
  agent_version? : String = "0.1.0",
  mcp_group? : @async.TaskGroup[Unit],
  mcp_mode? : @mcp.LoadMode = @mcp.LoadMode::Lazy,
) -> CetasAcpHost raise @posoco.CompositionError {
  let bridge = @ext_acp.AcpBridge()
  let fs = @workspace.NativeWorkspaceFs()
  let (agent, router, refreshables, refresh_snapshot) = build_native_agent(
    home~,
    cwd~,
    bridge,
    fs,
    mcp_group~,
    mcp_mode~,
  )
  {
    agent,
    bridge,
    version: agent_version,
    router,
    home,
    fs,
    contexts: Map::from_array([]),
    refreshables,
    refresh_snapshot,
    session_counter: 0,
    in_flight: Map::from_array([]),
  }
}

///|
/// Plan review over the same ACP reverse request the permission bridge
/// already speaks. The host may attach workspace integrity info (git
/// status) when rendering the request — product UX, not framework state.
struct AcpPlanReview {
  bridge : @ext_acp.AcpBridge
}

///|
impl @plan.PlanReviewSource for AcpPlanReview with fn review(
  self,
  request : @plan.PlanReviewRequest,
) -> @plan.PlanReviewDecision {
  let preview = if request.plan.length() <= 80 {
    request.plan
  } else {
    request.plan.sub(end=77).to_string() + "..."
  }
  let approval : @permission.ApprovalRequest = {
    tool_name: "exit_plan_mode",
    call_id: "plan-review",
    category: "plan",
    arguments_preview: preview,
    arguments: Json::object({ "plan": Json::string(request.plan) }),
  }
  match (self.bridge as &@permission.ApprovalSource).ask(approval) {
    AllowOnce | AllowSession | AllowAlways => @plan.PlanReviewDecision::Accept
    Deny(reason~) => @plan.PlanReviewDecision::Revise(feedback=reason)
  }
}

///|
/// Embedding and test constructor: wrap an already-composed agent, bridge,
/// router, and the fs the selection persists through. `refreshables` and
/// `refresh_snapshot` drive the lazy model refresh; tests substitute fake
/// refreshable factories here to exercise `refresh_model_lists` without a
/// network. Production code uses `CetasAcpHost`.
pub fn CetasAcpHost::of(
  agent~ : @posoco.Agent,
  bridge~ : @ext_acp.AcpBridge,
  router~ : @llm.RouterModelPort,
  home~ : String,
  fs~ : &@workspace.WorkspaceFs,
  agent_version? : String = "0.1.0",
  refreshables? : Array[&@llm.RefreshableProviderFactory] = [],
  refresh_snapshot? : @cetas_core.ProviderCredentialSnapshot = @cetas_core.ProviderCredentialSnapshot::ProviderCredentialSnapshot(),
) -> CetasAcpHost {
  {
    agent,
    bridge,
    version: agent_version,
    router,
    home,
    fs,
    contexts: Map::from_array([]),
    refreshables,
    refresh_snapshot,
    session_counter: 0,
    in_flight: Map::from_array([]),
  }
}

///|
/// The ACP endpoint specification for this host. Capabilities are derived
/// from service presence inside `colmugx/acp`: only the required session
/// operations plus `set_config_option` are wired (no
/// load/resume/list/delete/modes yet — v1), and image prompts are accepted
/// (`prompt_image=true`).
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
      set_config_option=(context, params) => {
        self.handle_set_config_option(context, params)
      },
    ),
    support=@acp.agent_support(prompt_image=true),
  )
}

///|
/// `session/new`: mint a fresh session id shared by both sides of the
/// bridge. The Posoco session store treats unknown ids as empty sessions,
/// so there is no create call. The router's model/effort selectors ride
/// along as configOptions (see `config_options.mbt`); with a seeded model
/// cache the full discovered list is announced here immediately, otherwise
/// the background refresh pushes a `config_option_update` once it lands.
pub fn CetasAcpHost::handle_new_session(
  self : CetasAcpHost,
  context : @acp.AgentContext,
  _params : @acp.NewSessionParams,
) -> @acp.NewSessionResult {
  self.session_counter += 1
  let session_id = "cetas-\{self.session_counter}"
  self.contexts[session_id] = context
  {
    session_id,
    modes: Omitted,
    config_options: Value(build_config_options(self.router)),
    meta: Omitted,
  }
}

///|
/// Render one turn failure for the client error channel: the error's own
/// display text, single-lined and length-bounded. The observer-facing
/// `TurnFailed` event stays category-only by contract (M0-T07 sanitized
/// terminal events); this is the host-to-client channel, where the detail is
/// the point — the user must be able to read, and paste to a developer, what
/// actually happened instead of a bare "AgentError::Model".
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
/// `session/prompt`: one turn with live streaming and cancellable execution.
///
/// The turn runs in its own task (registered per session) so
/// `session/cancel` can interrupt it; the pump task forwards queued updates
/// as they arrive. On completion the host flushes any remainder and closes
/// the pump scope (the next prompt's `attach` reopens the queue). A turn
/// failure raises a typed `HandlerError` carrying the full failure detail
/// (see `acp_failure_detail`), which the ACP engine settles as the prompt's
/// error response — the adapter forwards it verbatim to the client; a
/// cancelled turn settles as `stopReason: cancelled`.
pub async fn CetasAcpHost::handle_prompt(
  self : CetasAcpHost,
  context : @acp.AgentContext,
  params : @acp.PromptParams,
) -> @acp.PromptResult raise @acp.HandlerError {
  self.contexts[params.session_id] = context
  self.bridge.attach(context~, session_id=params.session_id)
  let outcome : Result[@acp.PromptResult, @acp.HandlerError] = @async.with_task_group(group => {
      self.bridge.spawn_pump(group)
      // allow_failure: the turn's AgentError is reported through task.wait()
      // below (sanitized via the bridge), not through the group's fail-fast
      // path, so the pump and this handler still settle in order.
      let task = group.spawn(
        () => {
          self.agent.run_turn(
            acp_prompt_to_message(params.prompt),
            params.session_id,
          )
        },
        allow_failure=true,
      )
      self.in_flight[params.session_id] = task
      let failure : Error? = try {
        let _ = task.wait()
        None
      } catch {
        error => Some(error)
      }
      ignore(self.in_flight.remove(params.session_id))
      ignore(self.bridge.flush())
      self.bridge.close()
      match failure {
        None => Ok({ stop_reason: self.bridge.stop_reason(), meta: Omitted })
        Some(error) =>
          if @async.is_cancellation_error(error) {
            Ok({ stop_reason: Cancelled, meta: Omitted })
          } else {
            // The raised error's display text carries the cause (transport
            // failure, hook rejection, ...); the bridge's TurnFailed text is
            // category-only (M0-T07) and never reaches the client from here.
            let detail = acp_failure_detail(error)
            acp_warn(
              "cetas-acp: session/prompt failed (session=\{params.session_id}): \{detail}\n",
            )
            Err(@acp.HandlerError::Application(message="cetas-acp: \{detail}"))
          }
      }
    },
  ) catch {
    // The group itself only fails through an unexpected pump defect; the
    // turn's own errors never reach this arm (allow_failure above).
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
  match outcome {
    Ok(result) => result
    Err(error) => raise error
  }
}

///|
/// `session/cancel`: interrupt the session's in-flight turn. The engine
/// invokes this handler for the notification; the prompt request settles
/// separately when the cancelled task unwinds.
pub fn CetasAcpHost::handle_cancel(
  self : CetasAcpHost,
  _context : @acp.AgentContext,
  params : @acp.CancelParams,
) -> Unit {
  match self.in_flight.get(params.session_id) {
    Some(task) => task.cancel()
    None => ()
  }
}

///|
/// Lazily refresh every refreshable provider's model list after startup:
/// refresh → persist the projected records to the model cache → hot-swap the
/// router's slots for that provider → push one `config_option_update` to
/// every live session so editors see the full list without a restart. Any
/// per-provider failure only warns on stderr and leaves the cached/static
/// slots standing; the process and its sessions are never at risk.
pub async fn CetasAcpHost::refresh_model_lists(
  self : CetasAcpHost,
) -> Unit noraise {
  let mut changed = false
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
        let swapped : Result[Unit, Error] = try {
          self.router.replace_provider_slots(provider_id, catalog.slots())
          Ok(())
        } catch {
          error => Err(error)
        }
        match swapped {
          Ok(_) => changed = true
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
  }
  if changed {
    self.push_config_option_update()
  }
}

///|
/// Push the router's current configOptions to every live session as a
/// `config_option_update`, so editors re-render the model/effort selectors
/// after a background refresh. Best-effort: a failing push warns and never
/// affects the process.
async fn CetasAcpHost::push_config_option_update(
  self : CetasAcpHost,
) -> Unit noraise {
  let config_options = build_config_options(self.router)
  for session_id, context in self.contexts {
    context.session_update({
      session_id,
      update: @acp.SessionUpdate::ConfigOptionUpdate({
        config_options,
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
  }
}

// ------------------------------------------------------- native assembly

///|
/// Compose the cetas agent for a native process: model router from
/// configured providers, JSONL session persistence, context files, the
/// cetas product extension, plan mode, the ACP bridge, and the default tool
/// set. Returns the agent together with its router, the refreshable provider
/// seams, and the credential snapshot so the host can lazily refresh model
/// lists after startup on the same inputs composition used.
///
/// The persisted active-model selection (`~/.cetas/settings.json` flat keys)
/// is restored onto the router before composition: a drifted slot or stale
/// effort degrades to the router default with one stderr warning (assembly
/// has no session/observer yet); malformed settings fail composition loudly.
/// The model-list disk cache (`~/.cetas/model_lists.json`) seeds provider
/// builds so a restart announces the full discovered list without a network
/// request; an unreadable cache warns once and degrades to static catalogs.
async fn build_native_agent(
  home~ : String,
  cwd~ : String,
  bridge : @ext_acp.AcpBridge,
  fs : &@workspace.WorkspaceFs,
  mcp_group~ : @async.TaskGroup[Unit]?,
  mcp_mode~ : @mcp.LoadMode,
) -> (
  @posoco.Agent,
  @llm.RouterModelPort,
  Array[&@llm.RefreshableProviderFactory],
  @cetas_core.ProviderCredentialSnapshot,
) raise @posoco.CompositionError {
  let settings = load_provider_settings(fs, home~)
  let ctx = @devkit.ExtContext::default()
  let factories = @cetas_core.all_provider_factories(ctx, settings)
  @cetas_core.validate_provider_settings(settings, factories)
  let store = @credentials.FileProviderCredentialStore(
    fs,
    home + "/.cetas/credentials",
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
        // One misconfigured provider must not take down the whole host:
        // skip it, warn on stderr, keep the healthy providers alive.
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
  // No OAuth interaction surface exists in an ACP stdio process (v1);
  // token refresh through the credential store still works for providers
  // whose credentials are already on disk.
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
  let router = @llm.RouterModelPort::from_catalogs(
    catalogs,
    default_slot_id~,
    provider_credential_store=Some(store as &@oauth.ProviderCredentialStore),
  )
  match selection {
    Some({ effort: Some(effort), .. }) =>
      if default_slot_id != "" {
        router.select_effort(default_slot_id, effort) catch {
          _ =>
            acp_warn(
              "cetas-acp: persisted reasoning effort '" +
              effort +
              "' is not advertised by model slot '" +
              default_slot_id +
              "'; using the slot's default effort\n",
            )
        }
      }
    _ => ()
  }
  let sessions = @fs_session.JsonlSessionStore(home + "/.cetas/sessions")
  // Context files (AGENTS.md / CLAUDE.md) are best-effort: a failure to
  // read them never blocks composition.
  let loader = @context.ContextLoader(fs, home~)
  let bundle = loader.load(cwd) catch { _ => @context.ContextBundle::empty() }
  let context_contributor = @context.ContextPromptContributor(
    bundle~,
    envelope="cetas-context",
  )
  // ACP surfaces tool approval through session/request_permission (the
  // bridge's ApprovalSource translation under the composed permission
  // policy), so the product UI port stays headless.
  let cetas = @cetas_core.Cetas(
    cwd~,
    ui=@posoco.NoopUiPort::NoopUiPort() as &@posoco.UiPort,
    context_contributor=Some(
      context_contributor as &@posoco.SystemPromptContributor,
    ),
    list_profiles=fn() { [] },
    on_load=fn(_name : String) { () },
    on_save=fn(_name : String) { () },
    on_delete=fn(_name : String) { () },
  )
  // Permission: the policy (modes, tool classification, session cache) is
  // ext-permission's; the ACP bridge is its approval source, translating
  // each ask into a session/request_permission the editor renders. Reads
  // are pre-approved; side-effecting tools go through the client's
  // decision UI. "Always allow" is remembered per the policy's call-shape
  // cache for the rest of the agent lifetime.
  let permission_policy = @permission.PermissionPolicy(
    @permission.Interactive,
    approval=Some(bridge as &@permission.ApprovalSource),
  )
  let acp_plan_review = AcpPlanReview::{ bridge, }
  let plan_mode = @plan.PlanMode(
    config={
      ..@plan.PlanModeConfig::default()
      // ask_question rides the permission read class.
      ,
      allowed_tools: ["read", "glob", "grep", "ask_question"],
      allow_model_entry: true,
    },
    review=Some(acp_plan_review as &@plan.PlanReviewSource),
  )
  let exts : Array[&@posoco.Extension] = [
    cetas,
    router as &@posoco.Extension,
    sessions as &@posoco.Extension,
    bridge as &@posoco.Extension,
    permission_policy,
    plan_mode,
  ]
  // Default features (six tools + agent skills + ask_question) take the host
  // context: the injected Workspace port plus cwd/home. Skills policy is
  // single-sourced inside cetas-core, so the ACP host gets skills for free;
  // ask_question's UI rides the bridge's UiPort view, which maps each ask
  // onto an ACP elicitation form (Unsupported → model-visible tool error
  // when the client has no elicitation capability).
  for
    tool in @cetas_core.build_default_features(
      ctx={ fs, cwd, home },
      ui=Some(bridge as &@posoco.UiPort),
    ) {
    exts.push(tool)
  }
  // MCP servers from mcp.json (`<cwd>/.mcp.json` overriding
  // `<home>/.cetas/mcp.json`), self-governed by the ext-mcp bridge. The
  // static routing table and catalog base are captured BEFORE the bridge
  // joins exts: the catalog source already appends the bridge's live tools,
  // so including them here would duplicate every MCP name.
  let mcp_bridge = match
    @mcp.MCPToolBridge::discover(cwd~, home~, mode=mcp_mode) {
    Ok(discovered) => discovered
    Err(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-acp.mcp",
        detail=message,
      )
  }
  match mcp_group {
    Some(group) => mcp_bridge.attach(group)
    None => ()
  }
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
  if mcp_mode is @mcp.LoadMode::Eager {
    // Composition happens once at process start; a raise here is degenerate
    // (async machinery), so it degrades to "no servers connected".
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
  exts.push(mcp_bridge as &@posoco.Extension)
  // Lazy activation changes the tool set mid-life, so the catalog is owned
  // by the runtime-seam source; MCP tool execution routes through the
  // decorator, everything else through the default port runtime.
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
  let agent = @posoco.Agent::with_runtime(
    exts~,
    config=@cetas_core.default_agent_config(),
    runtime=runtime as &@runtime.Runtime,
    catalog_source=catalog_source as &@runtime.CatalogSource,
  )
  // The lazy refresh runs against the same registry and snapshot composition
  // used. `device_id` stays empty: an ACP stdio process has no host crypto
  // surface, and providers mint a process-local id when handed "".
  let refreshables = @cetas_core.refreshable_factories(ctx)
  (agent, router, refreshables, snapshot)
}

///|
/// Read `~/.cetas/settings.json` and return its `providers` object. Missing
/// file means no settings; malformed content fails composition loudly.
async fn load_provider_settings(
  fs : &@workspace.WorkspaceFs,
  home~ : String,
) -> Map[String, Json] raise @posoco.CompositionError {
  let manifest_id = "cetas-acp.providers"
  match @workspace.read_file_result(fs, home + "/.cetas/settings.json") {
    Missing => Map::from_array([])
    Failed(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id~,
        detail=".cetas/settings.json read failed: " + message,
      )
    Content(text) => {
      let json = @json.parse(text) catch {
        _ =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id~,
            detail=".cetas/settings.json is not valid JSON",
          )
      }
      match json {
        Json::Object(fields) =>
          match fields.get("providers") {
            None => Map::from_array([])
            Some(Json::Object(providers)) => providers
            Some(_) =>
              raise @posoco.CompositionError::ManifestSchemaError(
                manifest_id~,
                detail="settings.providers must be an object",
              )
          }
        _ =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id~,
            detail=".cetas/settings.json must be an object",
          )
      }
    }
  }
}

///|
/// Read every provider's credential once into a snapshot map, mirroring the
/// cetas-js host: missing files and unconfigured providers map to no entry.
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
