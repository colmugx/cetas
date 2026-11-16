///|
/// session_assembly.mbt — host-agnostic per-session assembly over a
/// `CetasPlatform`, shared by every cetas host.

///|
/// The composed session pieces over a platform: everything a host needs to
/// mint and bind its agent. `exts` is the product extension list in product
/// order (host slots woven in); `routing`/`base_defs` are the tool table and
/// static catalog captured over `exts` before any host tail extension joins.
pub(all) struct CetasSession {
  /// The providers router, `None` only when the host injected a foreign
  /// model manager via `model_manager~`. Providers-only hosts go through
  /// `providers_router()`.
  router : @llm.RouterModelPort?
  /// The session's single ModelPort: the providers router, or the port of
  /// the host-injected model manager.
  model_port : &@posoco.ModelPort
  /// Manager-neutral control surface of the active model manager.
  model_control : &@modelmgmt.ModelManagerControl
  exts : Array[&@posoco.Extension]
  /// Session-private posoco event system: every `@kit_events` payload
  /// (today the `StatusChanged` ops `publish_status_*` emits) is delivered
  /// here, and the composed agent takes ownership of it. Hosts that need a
  /// listener before composition subscribe on this value directly.
  events : @posoco.EventSystem
  permission : @permission.PermissionPolicy
  ratelimit : @ratelimit.RateLimitGuard
  session_store : @fs_session.JsonlSessionStore
  routing : Map[String, &@posoco.ToolProvider]
  base_defs : Array[@posoco.ToolDef]
  config : @posoco.AgentConfig
  cwd : String
  session_fs : &@workspace.WorkspaceFs
}

///|
/// Mint an owner-bound publisher capability from the session's event system.
///
/// Extensions that publish protocol events but are constructed *below* the
/// composition layer (the llm router, the permission gate: peers report to
/// them by fire-and-forget before composition) take the capability through
/// their constructor instead of resolving it themselves. `owner` is the
/// extension id the envelope is tagged with. A closed system has no channel
/// left, so the capability is simply absent.
pub fn mint_events_publisher(
  system : @posoco.EventSystem,
  owner~ : String,
) -> @posoco.Events? {
  match system.publisher(owner~) {
    Ok(events) => Some(events)
    Err(_) => None
  }
}

///|
/// A host-injected model manager joining the composition at the router's
/// product position. The manager stays host-owned and opaque to core: it
/// contributes exactly one `Extension` (whose manifest carries the single
/// `ModelPort`), that port, and the manager-neutral control surface.
pub(all) struct CetasModelManager {
  extension : &@posoco.Extension
  port : &@posoco.ModelPort
  control : &@modelmgmt.ModelManagerControl
}

///|
/// The providers router of a session. Hosts that never inject a foreign
/// model manager can rely on the router always being present; a missing
/// router means the host composed the session with `model_manager~`.
pub fn CetasSession::providers_router(
  self : CetasSession,
) -> @llm.RouterModelPort raise @posoco.CompositionError {
  match self.router {
    Some(router) => router
    None =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas.session_assembly",
        detail="session composed without the providers model manager",
      )
  }
}

///|
/// Build the session router from the platform catalogs: the persisted
/// selection's slot (when still configured) plus the platform credential
/// store for on-disk token refresh. Hosts that must create router-adjacent
/// machinery before the session assembly (ACP: the bridge stamps the
/// active slot's context window) call this first and inject the router.
/// `events~` is the router's owner-bound publisher capability (mint it with
/// `mint_events_publisher`); without one the router publishes no status or
/// selection facts.
pub fn build_cetas_router(
  platform~ : CetasPlatform,
  events~ : @posoco.Events? = None,
  transient_retry~ : @llm.TransientRetryPolicy? = Some(
    @llm.TransientRetryPolicy::default(),
  ),
) -> @llm.RouterModelPort raise @posoco.CompositionError {
  @llm.RouterModelPort::from_catalogs(
    platform.catalogs,
    default_slot_id=platform.default_slot_id,
    allow_missing_default=platform.default_slot_pending,
    // The decision selection restores independently: an empty platform
    // value is the explicit-off state, and a pending id keeps the decision
    // capability off instead of silently picking another backend.
    default_decision_slot_id=platform.default_decision_slot_id,
    allow_missing_decision_default=platform.default_decision_slot_pending,
    events~,
    transient_retry~,
    model_metadata=Some(platform.model_metadata),
    provider_credential_store=Some(
      platform.credential_store as &@oauth.ProviderCredentialStore,
    ),
  )
}

///|
/// Assemble one session's product machinery over the platform. `router~`
/// injects a router built earlier via `build_cetas_router`; without one the
/// router is built here. `model_manager~` injects a foreign model manager
/// (host-owned `CetasModelManager`) that joins at the router's product
/// position instead: no router is built, the providers persisted-effort
/// seeding is skipped (the manager seeds itself), and it wins over an
/// injected `router~`. The persisted effort warning carries the host's
/// diagnostic `label~`. Injection seams keep protocol concerns host-side:
/// `approval~` carries the client bridge behind the permission policy and
/// `ui~` contributes the client bridge to the composition (as a
/// manifest-only `UiPortExtension`) for `Capability::Ui` consumers such as
/// ask_question, `client_exts~`/`policy_exts~` weave host extensions at
/// their product positions, `prompt_suffix~` appends a host profile section
/// to the cetas system prompt, and `session_fs~` substitutes a delegating
/// workspace shell. `events_exts~` builds extensions that publish or
/// subscribe at construction (the status bar, the exemption reporters): it
/// runs after this session's event system exists and after the permission
/// policy has subscribed, and it receives that system to mint its own
/// capabilities from, so such publications always reach a live gate.
/// `feature_exts~` is the host-owned composition root projection: concrete
/// extension selection is compiled outside cetas-core, while core retains the
/// authoritative product ordering and lifecycle. `transient_retry~` reaches
/// the internally built router only (an injected `router~` wins unchanged);
/// `None` disables model-call retrying, which scripted-failure tests use so
/// they surface the failure immediately instead of sleeping the default
/// backoff budget. `ratelimit_probe_ms~`/`ratelimit_max_probe_ms~` tune the
/// quota guard's recovery probing for managers whose rate-limit shape needs
/// faster cadence (e.g. gateways reporting transient failures without a
/// provider reset timestamp); `None` keeps the provider-stated defaults.
pub async fn build_cetas_session(
  platform~ : CetasPlatform,
  cwd~ : String,
  router~ : @llm.RouterModelPort? = None,
  model_manager~ : CetasModelManager? = None,
  transient_retry~ : @llm.TransientRetryPolicy? = Some(
    @llm.TransientRetryPolicy::default(),
  ),
  approval~ : &@permission.ApprovalSource? = None,
  ui~ : &@posoco.UiPort? = None,
  client_exts~ : Array[&@posoco.Extension] = [],
  policy_exts~ : Array[&@posoco.Extension] = [],
  events_exts~ : ((@posoco.EventSystem) -> Array[&@posoco.Extension])? = None,
  feature_exts~ : Array[&@posoco.Extension] = [],
  /// Host task group for provider-owned tool planes (remote MCP connections).
  /// `None` composes no provider tools: a host without a long-lived group must
  /// not get connections whose lifetime nobody owns.
  tool_plane_group~ : @async.TaskGroup? = None,
  prompt_suffix~ : String? = None,
  session_fs~ : &@workspace.WorkspaceFs? = None,
  ratelimit_probe_ms~ : Int64? = None,
  ratelimit_max_probe_ms~ : Int64? = None,
  label~ : String = "cetas-acp",
  warn~ : async (String) -> Unit noraise = fn(_ : String) { () },
) -> CetasSession raise @posoco.CompositionError {
  // Session-private so status/model/permission facts never leak into another
  // session. The posoco event system is the live channel for cross-extension
  // protocol events (`@kit_events`); it is created before any publisher
  // exists and handed to the agent for exclusive ownership by
  // `compose_cetas_agent`.
  let events = @posoco.EventSystem()
  // Provider model ports publish below this composition layer, so they reach
  // the session's system by process identity; this registration is what points
  // those publishes at this session's channel.
  @devkit.events_system_register(events)
  // One model manager joins at the router's product position: the providers
  // router (default, with its persisted-effort seeding) or the host-injected
  // foreign manager.
  let resolved : (CetasModelManager, @llm.RouterModelPort?) = match
    model_manager {
    Some(manager) => (manager, None)
    None => {
      let router = match router {
        Some(router) => router
        None =>
          build_cetas_router(
            platform~,
            events=mint_events_publisher(events, owner="posoco_ext_llm"),
            transient_retry~,
          )
      }
      match platform.persisted_effort {
        Some(effort) =>
          if platform.default_slot_id != "" && !platform.default_slot_pending {
            router.select_effort(platform.default_slot_id, effort) catch {
              _ =>
                warn(
                  label +
                  ": persisted reasoning effort '" +
                  effort +
                  "' is not advertised by model slot '" +
                  platform.default_slot_id +
                  "'; using the slot's default effort\n",
                )
            }
          }
        None => ()
      }
      (
        {
          extension: router as &@posoco.Extension,
          port: router as &@posoco.ModelPort,
          control: router as &@modelmgmt.ModelManagerControl,
        },
        Some(router),
      )
    }
  }
  // Context files (AGENTS.md/CLAUDE.md) are best-effort: a read failure
  // never blocks composition.
  let loader = @context.ContextLoader(platform.fs, home=platform.home)
  let bundle = loader.load(cwd) catch { _ => @context.ContextBundle::empty() }
  let context_contributor = @context.ContextPromptContributor(
    bundle~,
    ns="cetas",
  )
  let cetas = Cetas(
    context_contributor=Some(
      context_contributor as &@posoco.SystemPromptContributor,
    ),
  )
  // The gate subscribes at construction: peers report tool exemptions
  // (plan mode) fire-and-forget before composition, and the channel keeps no
  // history. That is why the capability is minted here and why `events_exts~`
  // below may only build extensions after this point.
  let permission_policy = @permission.PermissionPolicy(
    platform.permission_mode,
    approval~,
    events=mint_events_publisher(events, owner="posoco_ext_permission"),
    // The launch directory anchors WorkspaceWrite's in-workspace write
    // pre-approval; same root the file tools resolve against.
    workspace=Some(@devkit.WorkspaceAnchor(cwd)),
  )
  let exts : Array[&@posoco.Extension] = [
    cetas,
    resolved.0.extension,
    platform.session_store as &@posoco.Extension,
  ]
  for ext in client_exts {
    exts.push(ext)
  }
  // The host-constructed UI joins the composition as a manifest-only
  // extension, so the aggregated UiPort (and its core request-event wrapper)
  // sees it and `Capability::Ui` consumers capture the composed port.
  match ui {
    Some(port) =>
      exts.push(
        UiPortExtension::UiPortExtension(id=label + "_ui", ui=port)
        as &@posoco.Extension,
      )
    None => ()
  }
  exts.push(permission_policy)
  for ext in policy_exts {
    exts.push(ext)
  }
  // Exts that publish or subscribe at construction (the status bar, plan's
  // tool exemptions) must be built after the permission gate subscribes and
  // before the routing capture, so their manifest tools are routable.
  match events_exts {
    Some(build) =>
      for ext in build(events) {
        exts.push(ext)
      }
    None => ()
  }
  // Records quota verdicts per session and re-runs the interrupted session
  // at the provider-stated reset time; one guard per session agent. Its event
  // capability and background lifetime are its own (Lifecycle on_compose plus
  // the host-supplied core-async group), so nothing is handed in here.
  let ratelimit = match (ratelimit_probe_ms, ratelimit_max_probe_ms) {
    (Some(probe), Some(max)) =>
      @ratelimit.RateLimitGuard(
        probe_interval_ms=probe,
        max_probe_interval_ms=max,
      )
    (Some(probe), None) => @ratelimit.RateLimitGuard(probe_interval_ms=probe)
    (None, Some(max)) => @ratelimit.RateLimitGuard(max_probe_interval_ms=max)
    (None, None) => @ratelimit.RateLimitGuard()
  }
  exts.push(ratelimit as &@posoco.Extension)
  let session_fs = match session_fs {
    Some(fs) => fs
    None => platform.fs
  }
  for ext in feature_exts {
    exts.push(ext)
  }
  // Provider-owned tool planes join after the host's feature selection: they
  // are part of the provider's own surface, not of the compiled recipe.
  match tool_plane_group {
    Some(group) =>
      for
        ext in provider_tool_extensions(
          platform.fs,
          home=platform.home,
          label~,
          group~,
          initial_slot_id=resolved.0.control.active_selection().model_id,
        ) {
        exts.push(ext)
      }
    None => ()
  }

  // The routing table and catalog base are captured BEFORE any host tail
  // extension joins: a decorator source (ACP: the MCP bridge) appends its
  // own live tools, so including them here would duplicate every name.
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
  let config = default_agent_config(
    system_prompt=Some(
      match prompt_suffix {
        Some(suffix) => cetas_system_prompt(cwd~) + "\n\n" + suffix
        None => cetas_system_prompt(cwd~)
      },
    ),
  )
  {
    router: resolved.1,
    model_port: resolved.0.port,
    model_control: resolved.0.control,
    exts,
    events,
    permission: permission_policy,
    ratelimit,
    session_store: platform.session_store,
    routing,
    base_defs,
    config,
    cwd,
    session_fs,
  }
}

///|
/// Compose the Agent from the session pieces. Hosts that decorate tool
/// execution append their decorator extensions via `tail_exts~` (ACP: the
/// MCP bridge) and pass the wrapping `runtime~`; a plain host composes the
/// default runtime. Dynamic tool faces are extension-owned contribution
/// groups now — the retired `catalog_source~` seam is gone. `runtime_group~`
/// attaches the quota guard to the composed agent and starts its rate-limit
/// runtime on the host lifetime; production hosts should always provide it.
/// The group is the core-async one: the guard, the recovery runtime and
/// fuwaroid all run on it, independent of the host's I/O group.
pub fn compose_cetas_agent(
  session~ : CetasSession,
  tail_exts~ : Array[&@posoco.Extension] = [],
  runtime~ : &@runtime.Runtime? = None,
  runtime_group~ : @async.TaskGroup? = None,
) -> @posoco.Agent raise @posoco.CompositionError {
  for ext in tail_exts {
    session.exts.push(ext)
  }
  // The agent takes ownership of the session's event system (0.24.1 requires
  // it): listeners registered before composition keep receiving in
  // registration order, and capabilities minted earlier stay valid.
  let agent = match runtime {
    Some(runtime) =>
      @posoco.Agent::with_runtime(
        exts=session.exts,
        config=session.config,
        events=session.events,
        runtime~,
      )
    None =>
      @posoco.Agent(
        exts=session.exts,
        config=session.config,
        events=session.events,
      )
  }
  // Recovery owns its mutable state and async effects inside the host task
  // group. Tests and embedders without a lifetime group simply compose the
  // extension without starting recovery.
  match runtime_group {
    Some(group) => session.ratelimit.start(group~, agent~)
    None => ()
  }
  agent
}
