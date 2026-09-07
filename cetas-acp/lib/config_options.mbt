///|
/// config_options.mbt — the ACP config-option surface of the cetas host.
///
/// `session/new` advertises `model` / `effort` selectors over the session
/// router's slots; `session/set_config_option` routes ids through the
/// calling session's router and persists model/effort to
/// `~/.cetas/settings.json` as the next launch's default. `permission`
/// exposes the session's tool-approval posture: runtime-only,
/// session-scoped, never persisted.

///|
/// The async runtime's shared stderr handle panics on overlapping writes
/// (`guard! write is Idle`), so every stderr write serializes on this.
let acp_stderr_mutex : @async.Mutex = @async.Mutex::Mutex()

///|
/// Both persistence points are read-merge-write cycles, so two interleaved
/// cycles would silently drop one side's merged update; each whole cycle
/// runs under this lock.
let acp_persist_mutex : @async.Mutex = @async.Mutex::Mutex()

///|
/// Best-effort stderr diagnostic: warnings never fail a selection switch.
async fn acp_warn(message : String) -> Unit noraise {
  acp_stderr_mutex.acquire() catch {
    // Cancelled while queued: skip the diagnostic rather than write
    // unserialized or release a lock we never acquired.
    _ => return
  }
  defer acp_stderr_mutex.release()
  @stdio.stderr.write(message) catch {
    _ => ()
  }
}

// ------------------------------------------------------------- permission

///|
fn read_env_var(key : String) -> String? {
  @env.get_env_var(key)
}

///|
/// The same names ext-permission's `/permission` command accepts.
fn permission_mode_value(mode : @permission.PermissionMode) -> String {
  match mode {
    ReadOnly => "readonly"
    WorkspaceWrite => "workspace_write"
    Interactive => "interactive"
    Yolo => "yolo"
  }
}

///|
fn parse_permission_mode_name(raw : String) -> @permission.PermissionMode? {
  match raw {
    "readonly" => Some(ReadOnly)
    "workspace_write" => Some(WorkspaceWrite)
    "interactive" => Some(Interactive)
    "yolo" => Some(Yolo)
    _ => None
  }
}

///|
/// Unset means the workspace_write default; an unrecognized value falls
/// back to workspace_write with one warning (a typo never widens to
/// interactive/yolo).
async fn resolve_startup_permission_mode(
  env_value : String?,
) -> @permission.PermissionMode noraise {
  match env_value {
    None => WorkspaceWrite
    Some(raw) =>
      match parse_permission_mode_name(raw) {
        Some(mode) => mode
        None => {
          acp_warn(
            "cetas-acp: CETAS_PERMISSION_MODE '" +
            raw +
            "' is not one of readonly/workspace_write/interactive/yolo; using workspace_write\n",
          )
          WorkspaceWrite
        }
      }
  }
}

///|
async fn startup_permission_mode() -> @permission.PermissionMode noraise {
  resolve_startup_permission_mode(read_env_var("CETAS_PERMISSION_MODE"))
}

///|
fn tk_select_option(
  value : String,
  name : String,
) -> @acp.SessionConfigSelectOption {
  { value, name, description: Omitted, meta: Omitted, }
}

///|
fn slot_display_name(slot : @llm.ModelSlot) -> String {
  if slot.label.length() == 0 {
    slot.id
  } else {
    slot.label
  }
}

///|
fn current_effort_value(
  explicit : String?,
  default_effort : String?,
  efforts : Array[String],
) -> String {
  match explicit {
    Some(effort) => effort
    None =>
      match default_effort {
        Some(effort) => effort
        None => efforts[0]
      }
  }
}

///|
fn build_config_options(
  router : @llm.RouterModelPort,
  permission_mode : @permission.PermissionMode,
) -> Array[@acp.SessionConfigOption] {
  let options : Array[@acp.SessionConfigSelectOption] = []
  for slot in router.list_slots() {
    options.push(tk_select_option(slot.id, slot_display_name(slot)))
  }
  let model : @acp.SessionConfigOption = {
    id: "model",
    name: "Model",
    description: Omitted,
    category: Value(@acp.SessionConfigOptionCategory::Model),
    kind: @acp.SessionConfigOptionKind::Select({
      current_value: router.active_slot_id(),
      options: @acp.SessionConfigSelectOptions::Ungrouped(options),
    }),
    meta: Omitted,
  }
  let permission : @acp.SessionConfigOption = {
    id: "permission",
    name: "Permission",
    description: Value(
      "Tool approval posture for this session. Runtime-only: unlike model/effort, a switch is not persisted as the next launch's default.",
    ),
    category: Value(@acp.SessionConfigOptionCategory::Mode),
    kind: @acp.SessionConfigOptionKind::Select({
      current_value: permission_mode_value(permission_mode),
      options: @acp.SessionConfigSelectOptions::Ungrouped([
        tk_select_option("readonly", "Read-only"),
        tk_select_option("workspace_write", "Workspace write"),
        tk_select_option("interactive", "Interactive"),
        tk_select_option("yolo", "Yolo (no approval)"),
      ]),
    }),
    meta: Omitted,
  }
  let config_options : Array[@acp.SessionConfigOption] = [model, permission]
  let active_id = router.active_slot_id()
  for slot in router.list_slots() {
    if slot.id == active_id && !slot.thinking_efforts.is_empty() {
      let effort_options : Array[@acp.SessionConfigSelectOption] = []
      for effort in slot.thinking_efforts {
        effort_options.push(tk_select_option(effort, effort))
      }
      let effort_option : @acp.SessionConfigOption = {
        id: "effort",
        name: "Effort",
        description: Omitted,
        category: Value(@acp.SessionConfigOptionCategory::ThoughtLevel),
        kind: @acp.SessionConfigOptionKind::Select({
          current_value: current_effort_value(
            router.active_effort(),
            slot.default_effort,
            slot.thinking_efforts,
          ),
          options: @acp.SessionConfigSelectOptions::Ungrouped(effort_options),
        }),
        meta: Omitted,
      }
      config_options.push(effort_option)
    }
  }
  config_options
}

///|
/// Apply one `session/set_config_option`. `model`/`effort` retune the
/// session router and persist as the next launch's default; `permission`
/// switches the session policy's mode in place, deliberately NOT persisted.
/// A persistence failure is NOT an error — the in-memory switch already
/// committed, so it only warns.
async fn apply_config_option(
  router : @llm.RouterModelPort,
  policy : @permission.PermissionPolicy,
  fs : &@workspace.WorkspaceFs,
  home : String,
  config_id : String,
  value : @acp.SessionConfigValue,
) -> Result[Array[@acp.SessionConfigOption], String] noraise {
  let value_id = match value {
    @acp.SessionConfigValue::ValueId(id) => id
    @acp.SessionConfigValue::Boolean(_) =>
      return Err("config option '" + config_id + "' expects a value id")
  }
  let outcome : Result[Unit, String] = match config_id {
    "model" =>
      if !router.list_slot_ids().contains(value_id) {
        Err("unknown model slot: " + value_id)
      } else {
        try {
          router.switch_slot(value_id)
          Ok(())
        } catch {
          _ => Err("failed to switch model slot: " + value_id)
        }
      }
    "effort" =>
      try {
        router.select_effort(router.active_slot_id(), value_id)
        Ok(())
      } catch {
        @posoco.CommandError::InvalidArgs(reason~) => Err(reason)
        @posoco.CommandError::ExecutionFailed(reason) => Err(reason)
        @posoco.CommandError::NotFound(reason) => Err(reason)
      }
    "permission" =>
      match parse_permission_mode_name(value_id) {
        Some(mode) => {
          policy.mode = mode
          Ok(())
        }
        None => Err("unknown permission mode: " + value_id)
      }
    _ => Err("unknown config option: " + config_id)
  }
  let persist_selection = config_id != "permission"
  match outcome {
    Err(message) => Err(message)
    Ok(_) => {
      if persist_selection {
        persist_active_model_selection(fs, home, router)
      }
      Ok(build_config_options(router, policy.mode))
    }
  }
}

///|
/// Runs under the process persistence mutex so a concurrent switch on
/// another session cannot interleave its own read-merge-write against this
/// one. A failure warns; the in-memory switch is never overturned.
async fn persist_active_model_selection(
  fs : &@workspace.WorkspaceFs,
  home : String,
  router : @llm.RouterModelPort,
) -> Unit noraise {
  acp_persist_mutex.acquire() catch {
    _ => {
      acp_warn(
        "cetas-acp: model selection persistence skipped (mutex cancelled)\n",
      )
      return
    }
  }
  defer acp_persist_mutex.release()
  @cetas_core.write_active_model_selection(
    fs,
    home~,
    @cetas_core.ActiveModelSelection::from_current(
      router.active_slot_id(),
      router.active_effort(),
    ),
  ) catch {
    _ =>
      acp_warn(
        "cetas-acp: failed to persist the model selection to " +
        home +
        "/.cetas/settings.json; the change is active for this process only\n",
      )
  }
}

///|
/// `session/set_config_option`: switch the session's model/effort
/// (persisted) or permission posture (runtime-only), answer with the
/// refreshed configOptions, and best-effort push a
/// `config_option_update` to the requesting client. Invalid ids/values
/// reject with a typed application error; a persistence failure does not.
pub async fn CetasAcpHost::handle_set_config_option(
  self : CetasAcpHost,
  context : @acp.AgentContext,
  params : @acp.SetSessionConfigOptionParams,
) -> @acp.SetSessionConfigOptionResult raise @acp.HandlerError {
  let handle = self.require_session(params.session_id)
  match
    apply_config_option(
      handle.router,
      handle.permission,
      self.fs,
      self.home,
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
          acp_warn(
            "cetas-acp: config_option_update push failed (session=\{params.session_id})\n",
          )
      }
      { config_options, meta: Omitted, }
    }
    Err(message) =>
      raise @acp.HandlerError::Application(message="cetas-acp: " + message)
  }
}
