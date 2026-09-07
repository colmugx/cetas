///|
/// host.mbt — the headless host: one process, one session, one agent.
///
/// Assembly rides the shared cetas-core seam so headless stays "the same
/// cetas, another shell": `build_cetas_platform` (settings → providers →
/// credentials → catalogs → fs-session JSONL store) once per process, then
/// `build_cetas_session` + `compose_cetas_agent` for the single session.
/// Host-specific wiring is only the approval source and UI port (both
/// terminal-side, or absent under `--yolo`), plus the personal zcode opt-in
/// below — no askquestion bridge beyond
/// what `ui~` already buys, and HerdrReporter comes free via
/// `build_default_features`' default `detect_herdr`.
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
}

///|
/// Compose the production headless host. `mode~` is the resolved startup
/// posture (see `resolve_permission_mode`); `approval~`/`ui~` are None under
/// `--yolo`. `tail_exts~` weaves host-side extensions at the composition
/// tail (ACP precedent: the `--jsonl` observer rides here). `fs~`
/// substitutes the workspace fs in tests; production passes None for the
/// native fs.
pub async fn CetasHeadlessHost::CetasHeadlessHost(
  home~ : String,
  cwd~ : String,
  mode~ : @permission.PermissionMode,
  approval~ : &@permission.ApprovalSource?,
  ui~ : &@posoco.UiPort?,
  model_override? : String = "",
  effort_override? : String = "",
  session_id? : String = "",
  mcp_group? : @async.TaskGroup[Unit]? = None,
  tail_exts? : Array[&@posoco.Extension] = [],
  enable_nmem? : Bool? = None,
  fs? : &@workspace.WorkspaceFs? = None,
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
  let nmem = match enable_nmem {
    Some(enabled) => enabled
    // Mirror cetas-core's committed "auto" flavor default for dev builds.
    None => @env.get_env_var("CETAS_NMEM") == Some("1")
  }
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
  let session = @cetas_core.build_cetas_session(
    platform~,
    cwd~,
    approval~,
    ui~,
    enable_nmem=nmem,
    client_exts=match zcode_ext {
      Some(ext) => [ext as &@posoco.Extension]
      None => []
    },
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
  let agent = @cetas_core.compose_cetas_agent(session~, tail_exts~)
  let sid = if session_id.length() > 0 {
    session_id
  } else {
    @cetas_core.mint_session_id()
  }
  { home, cwd, agent, router: session.router, session_id: sid, }
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
