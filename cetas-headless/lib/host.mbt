///|
/// host.mbt — the headless host: one process, one session, one agent.
///
/// Assembly rides the shared cetas-core seam so headless stays "the same
/// cetas, another shell": `build_cetas_platform` (settings → providers →
/// credentials → catalogs → fs-session JSONL store) once per process, then
/// `build_cetas_session` + `compose_cetas_agent` for the single session.
/// Host-specific wiring is only the approval source and UI port (both
/// terminal-side, or absent under `--yolo`) — no askquestion bridge beyond
/// what `ui~` already buys.
///
/// `--model` / `--effort` are run-scoped: they override the persisted
/// `ActiveModelSelection` on the session router and are NEVER written back
/// to `~/.cetas/settings.json`. An override that names no configured slot,
/// or a level the slot rejects, fails composition with the valid vocabulary
/// listed — a one-shot CLI must exit loudly, never silently serve the
/// persisted selection the operator just overruled.

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
  tail_exts? : Array[&@posoco.Extension] = [],
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
    label~,
    warn~,
  )
  let client_exts : Array[&@posoco.Extension] = []
  // Headless reports presence to herdr when running inside a pane.
  match @herdr.HerdrReporter::detect() {
    Some(reporter) => client_exts.push(reporter as &@posoco.Extension)
    None => ()
  }
  let session = @cetas_core.build_cetas_session(
    platform~,
    cwd~,
    approval~,
    ui~,
    client_exts~,
    label~,
    warn~,
  )
  apply_model_override(
    session.router,
    platform.catalogs,
    model=model_override,
    effort=effort_override,
    label~,
  )
  let agent = @cetas_core.compose_cetas_agent(session~, tail_exts~)
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
/// Apply the run-scoped overrides onto the session router (before compose,
/// so the same session router the agent rides serves the turn). A bad
/// override raises instead of degrading: `--model` must name a configured
/// slot and `--effort` must be advertised by the active slot, and each
/// failure message lists the valid vocabulary. Neither path persists.
fn apply_model_override(
  router : @llm.RouterModelPort,
  catalogs : Array[@llm.ProviderModelCatalog],
  model~ : String,
  effort~ : String,
  label~ : String,
) -> Unit raise @posoco.CompositionError {
  if model.length() > 0 {
    let selection = if effort.length() > 0 {
      @cetas_core.ActiveModelSelection::ActiveModelSelection(model, effort~)
    } else {
      @cetas_core.ActiveModelSelection::ActiveModelSelection(model)
    }
    let slot = @cetas_core.resolve_default_slot_id(catalogs, Some(selection))
    if slot == "" {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=label + ".model_override",
        detail="unknown --model '\{model}' — available model slots: \{comma_joined(router.list_slot_ids())}",
      )
    }
    // resolve guarantees the slot exists in the catalogs; a router missing
    // it means the two views drifted apart mid-composition — fail loudly.
    router.switch_slot(slot) catch {
      error =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id=label + ".model_override",
          detail="--model '\{model}' switch failed: \{error.to_string()}",
        )
    }
  }
  if effort.length() > 0 {
    let slot = router.active_slot_id()
    router.select_effort(slot, effort) catch {
      error => {
        let advertised = slot_advertised_efforts(router, slot)
        let supported = if advertised.is_empty() {
          "none advertised"
        } else {
          comma_joined(advertised)
        }
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id=label + ".model_override",
          detail="--effort '\{effort}' rejected by model slot '\{slot}' (supported efforts: \{supported}): \{error.to_string()}",
        )
      }
    }
  }
}

///|
/// Comma-join for one-line error vocabularies, in composition order.
fn comma_joined(items : Array[String]) -> String {
  let builder = StringBuilder()
  for i, item in items {
    if i > 0 {
      builder.write_string(", ")
    }
    builder.write_string(item)
  }
  builder.to_string()
}

///|
/// The efforts one router slot advertises; empty when the slot is missing.
fn slot_advertised_efforts(
  router : @llm.RouterModelPort,
  slot_id : String,
) -> Array[String] {
  for slot in router.list_slots() {
    if slot.id == slot_id {
      return slot.thinking_efforts
    }
  }
  []
}
