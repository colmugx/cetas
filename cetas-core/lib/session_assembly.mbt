///|
/// session_assembly.mbt — host-agnostic per-session assembly over a
/// `CetasPlatform`, shared by every cetas host.

///|
/// The composed session pieces over a platform: everything a host needs to
/// mint and bind its agent. `exts` is the product extension list in product
/// order (host slots woven in); `routing`/`base_defs` are the tool table and
/// static catalog captured over `exts` before any host tail extension joins.
pub(all) struct CetasSession {
  router : @llm.RouterModelPort
  exts : Array[&@posoco.Extension]
  event_bus : @devkit.EventBus
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
/// Build the session router from the platform catalogs: the persisted
/// selection's slot (when still configured) plus the platform credential
/// store for on-disk token refresh. Hosts that must create router-adjacent
/// machinery before the session assembly (ACP: the bridge stamps the
/// active slot's context window) call this first and inject the router.
pub fn build_cetas_router(
  platform~ : CetasPlatform,
) -> @llm.RouterModelPort raise @posoco.CompositionError {
  @llm.RouterModelPort::from_catalogs(
    platform.catalogs,
    default_slot_id=platform.default_slot_id,
    provider_credential_store=Some(
      platform.credential_store as &@oauth.ProviderCredentialStore,
    ),
  )
}

///|
/// Assemble one session's product machinery over the platform. `router~`
/// injects a router built earlier via `build_cetas_router`; without one the
/// router is built here. The persisted effort warning carries the host's
/// diagnostic `label~`. Injection seams keep protocol concerns host-side:
/// `approval~`/`ui~` carry the client bridge behind the permission policy
/// and ask_question, `client_exts~`/`policy_exts~` weave host extensions at
/// their product positions, `prompt_suffix~` appends a host profile section
/// to the cetas system prompt, and `session_fs~` substitutes a delegating
/// workspace shell. `bus_exts~` builds extensions that publish to the bus at
/// construction (e.g. tool exemptions): it runs only after the policy has
/// subscribed, so such publications always reach a live gate.
pub async fn build_cetas_session(
  platform~ : CetasPlatform,
  cwd~ : String,
  router? : @llm.RouterModelPort? = None,
  approval? : &@permission.ApprovalSource? = None,
  ui? : &@posoco.UiPort? = None,
  event_bus? : @devkit.EventBus? = None,
  client_exts? : Array[&@posoco.Extension] = [],
  policy_exts? : Array[&@posoco.Extension] = [],
  bus_exts? : ((@devkit.EventBus) -> Array[&@posoco.Extension])? = None,
  prompt_suffix? : String? = None,
  session_fs? : &@workspace.WorkspaceFs? = None,
  label? : String = "cetas-acp",
  warn? : async (String) -> Unit noraise = fn(_ : String) { () },
) -> CetasSession raise @posoco.CompositionError {
  let router = match router {
    Some(router) => router
    None => build_cetas_router(platform~)
  }
  match platform.persisted_effort {
    Some(effort) =>
      if platform.default_slot_id != "" {
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
  // Session-private so plan/permission facts never leak into another's hooks.
  let event_bus = match event_bus {
    Some(bus) => bus
    None => @devkit.EventBus()
  }
  let permission_policy = @permission.PermissionPolicy(
    platform.permission_mode,
    approval~,
    bus=Some(event_bus),
  )
  let exts : Array[&@posoco.Extension] = [
    cetas,
    router as &@posoco.Extension,
    platform.session_store as &@posoco.Extension,
  ]
  for ext in client_exts {
    exts.push(ext)
  }
  exts.push(permission_policy)
  for ext in policy_exts {
    exts.push(ext)
  }
  // Exts that publish to the bus at construction (e.g. plan's tool
  // exemptions) must be built after the policy subscribes and before the
  // routing capture, so their manifest tools are routable.
  match bus_exts {
    Some(build) =>
      for ext in build(event_bus) {
        exts.push(ext)
      }
    None => ()
  }
  // Records quota verdicts per session and re-runs the interrupted session
  // at the provider-stated reset time; one guard per session agent.
  let ratelimit = @ratelimit.RateLimitGuard()
  exts.push(ratelimit as &@posoco.Extension)
  let session_fs = match session_fs {
    Some(fs) => fs
    None => platform.fs
  }
  for
    tool in build_default_features(
      ctx={ fs: session_fs, cwd, home: platform.home, },
      ui~,
      nmem_group=platform.mcp_group,
    ) {
    exts.push(tool)
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
    router,
    exts,
    event_bus,
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
/// MCP bridge) and pass the wrapping `runtime~`/`catalog_source~`; a plain
/// host composes the default runtime. Binds the quota guard to the composed
/// agent either way.
pub fn compose_cetas_agent(
  session~ : CetasSession,
  tail_exts? : Array[&@posoco.Extension] = [],
  runtime? : &@runtime.Runtime? = None,
  catalog_source? : &@runtime.CatalogSource? = None,
) -> @posoco.Agent raise @posoco.CompositionError {
  for ext in tail_exts {
    session.exts.push(ext)
  }
  let agent = match (runtime, catalog_source) {
    (Some(runtime), Some(source)) =>
      @posoco.Agent::with_runtime(
        exts=session.exts,
        config=session.config,
        runtime~,
        catalog_source=source,
      )
    (Some(runtime), None) =>
      @posoco.Agent::with_runtime(
        exts=session.exts,
        config=session.config,
        runtime~,
      )
    (None, _) => @posoco.Agent(exts=session.exts, config=session.config)
  }
  // The guard re-runs turns itself, so it needs the composed agent.
  session.ratelimit.bind(agent)
  agent
}
