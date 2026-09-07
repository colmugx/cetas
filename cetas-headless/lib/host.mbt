///|
/// host.mbt — the headless host: one process, one session, one agent.
///
/// Assembly rides the shared cetas-core seam so headless stays "the same
/// cetas, another shell": `build_cetas_platform` (settings → providers →
/// credentials → catalogs → fs-session JSONL store) once per process, then
/// `build_cetas_session` + `compose_cetas_agent` for the single session.
/// Host-specific wiring is only the approval source and UI port (both
/// terminal-side, or absent under `--yolo`), plus the personal zcode opt-in
/// below — no askquestion bridge beyond what `ui~` already buys.
///
/// `--model` / `--effort` are run-scoped: they override the persisted
/// `ActiveModelSelection` on the session router and are NEVER written back
/// to `~/.cetas/settings.json`.

///|
pub struct CetasHeadlessHost {
  home : String
  cwd : String
  /// The composed agent; `run_one_turn` drives the single turn.
  agent : @posoco.Agent
  /// The session router (model/effort selection surface).
  router : @llm.RouterModelPort
  /// Minted fresh or resumed from `--session <id>`.
  session_id : String
  /// The session's captured tool routing (base table, before any tail ext).
  routing : Map[String, &@posoco.ToolProvider]
}

///|
/// Compose the production headless host. `mode~` is the resolved startup
/// posture (see `resolve_permission_mode`); `approval~`/`ui~` are None under
/// `--yolo`. `tail_exts~` weaves host-side extensions at the composition
/// tail (ACP precedent: the `--jsonl` observer rides here). `fs~`
/// substitutes the workspace fs in tests; production passes None for the
/// native fs. `goal~` arms the goal runner (`--goal`). `tty~` feeds the
/// terminal plan review; without one the review degrades to Dismiss.
pub async fn CetasHeadlessHost::CetasHeadlessHost(
  home~ : String,
  cwd~ : String,
  mode~ : @permission.PermissionMode,
  approval~ : &@permission.ApprovalSource?,
  ui~ : &@posoco.UiPort?,
  model_override? : String = "",
  effort_override? : String = "",
  session_id? : String = "",
  goal? : String = "",
  mcp_group? : @async.TaskGroup[Unit]? = None,
  tail_exts? : Array[&@posoco.Extension] = [],
  fs? : &@workspace.WorkspaceFs? = None,
  tty? : TtyChannel? = None,
  label? : String = "cetas-headless",
  warn? : async (String) -> Unit noraise = async fn(text : String) noraise {
    @stdio.stderr.write(text) catch {
      _ => ()
    }
  },
) -> CetasHeadlessHost raise @posoco.CompositionError {
  let fs : &@workspace.WorkspaceFs = match fs {
    Some(fs) => fs
    None => @workspace.NativeWorkspaceFs()
  }
  let platform = @cetas_core.build_cetas_platform(
    home~,
    cwd~,
    fs,
    permission_mode=mode,
    mcp_group~,
    label~,
    warn~,
  )
  // Personal host opt-in: zcode delegation registers when detected, degrades to absent otherwise.
  let zcode_ext = @zcode.zcode_ext_if_detected(
    env=fn(key : String) { @env.get_env_var(key) },
    exists=async fn(path : String) -> Bool {
      fs.exists(path) catch {
        _ => false
      }
    },
  ) catch {
    _ => None
  }
  let client_exts : Array[&@posoco.Extension] = []
  match zcode_ext {
    Some(ext) => client_exts.push(ext as &@posoco.Extension)
    None => ()
  }
  // --goal arms the goal runner; its goal_update_plan tool must be routable,
  // so it rides client_exts ahead of the routing capture.
  if goal.trim().length() > 0 {
    client_exts.push(
      @goal.goal_extension(goal_condition=goal) as &@posoco.Extension,
    )
  }
  let session = @cetas_core.build_cetas_session(
    platform~,
    cwd~,
    approval~,
    ui~,
    client_exts~,
    bus_exts=Some(fn(bus) {
      // Same plan config as acp/js; the review is the terminal seam and it
      // must build here — after the policy subscribes, before the capture.
      [
        @plan.PlanMode(
          config={
            ..@plan.PlanModeConfig::default(),
            allowed_tools: ["read", "glob", "grep", "ask_question"],
            allow_model_entry: true,
          },
          review=Some(
            TerminalPlanReview::TerminalPlanReview(tty~, notice=warn)
            as &@plan.PlanReviewSource,
          ),
          bus=Some(bus),
          fs=Some(fs),
        )
        as &@posoco.Extension,
      ]
    }),
    label~,
    warn~,
  )
  apply_model_override(
    session.router,
    platform.catalogs,
    model=model_override,
    effort=effort_override,
    label~,
    warn~,
  )
  // MCP joins AFTER the routing capture (tail_exts): the bridge serves its
  // tools through the decorator runtime + catalog source, never the
  // manifest; a malformed mcp.json warns and skips MCP entirely.
  let bridge = match
    @mcp.MCPToolBridge::discover(cwd~, home~, mode=@mcp.LoadMode::Lazy) {
    Ok(bridge) => {
      match mcp_group {
        Some(group) => bridge.attach(group)
        None => ()
      }
      Some(bridge)
    }
    Err(message) => {
      warn(
        label + ": mcp.json discovery failed, MCP disabled: " + message + "\n",
      )
      None
    }
  }
  let agent = match bridge {
    Some(bridge) => {
      let base_runtime = @runtime.PortRuntime(
        model=session.router as &@posoco.ModelPort,
        tools=session.routing,
      )
      let runtime = @mcp.McpRuntime(
        bridge~,
        fallback=base_runtime as &@runtime.Runtime,
      )
      let catalog_source = @mcp.McpCatalogSource(
        bridge~,
        base_tools=session.base_defs,
      )
      let tails : Array[&@posoco.Extension] = [bridge as &@posoco.Extension]
      for ext in tail_exts {
        tails.push(ext)
      }
      @cetas_core.compose_cetas_agent(
        session~,
        tail_exts=tails,
        runtime=Some(runtime as &@runtime.Runtime),
        catalog_source=Some(catalog_source as &@runtime.CatalogSource),
      )
    }
    None => @cetas_core.compose_cetas_agent(session~, tail_exts~)
  }
  let sid = if session_id.length() > 0 {
    session_id
  } else {
    @cetas_core.mint_session_id()
  }
  {
    home,
    cwd,
    agent,
    router: session.router,
    session_id: sid,
    routing: session.routing,
  }
}

///|
/// Apply the run-scoped overrides onto the session router. An unknown
/// `--model` slot warns and keeps the composed selection (mirroring the
/// platform's drifted-persisted-selection warning); an unsupported effort
/// warns and keeps the slot's default. Neither path persists anything.
async fn apply_model_override(
  router : @llm.RouterModelPort,
  catalogs : Array[@llm.ProviderModelCatalog],
  model~ : String,
  effort~ : String,
  label~ : String,
  warn~ : async (String) -> Unit noraise,
) -> Unit noraise {
  if model.length() > 0 {
    let selection = if effort.length() > 0 {
      @cetas_core.ActiveModelSelection::ActiveModelSelection(model, effort~)
    } else {
      @cetas_core.ActiveModelSelection::ActiveModelSelection(model)
    }
    match @cetas_core.resolve_default_slot_id(catalogs, Some(selection)) {
      "" =>
        warn(
          label +
          ": --model '" +
          model +
          "' is not a configured model slot; keeping the active selection\n",
        )
      slot =>
        router.switch_slot(slot) catch {
          error =>
            warn(label + ": --model switch failed: " + error.to_string() + "\n")
        }
    }
  }
  if effort.length() > 0 {
    let slot = router.active_slot_id()
    router.select_effort(slot, effort) catch {
      error =>
        warn(
          label +
          ": --effort '" +
          effort +
          "' rejected by model slot '" +
          slot +
          "': " +
          error.to_string() +
          "\n",
        )
    }
  }
}
