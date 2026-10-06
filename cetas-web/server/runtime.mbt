///|
/// One running session: a composed agent plus its live turn state. Handles
/// run concurrently within a workspace; each owns its observer for event
/// attribution.
struct SessionHandle {
  agent : @posoco.Agent
  session_id : String
  cwd : String
  observer : WebObserver
  router : @ext_llm.RouterModelPort
  policy : @permission.PermissionPolicy
  mut model : String
  mut effort : String
  mut busy : Bool
  mut turn_no : Int
}

///|
/// One workspace = one independent Cetas: its own platform (cwd-scoped
/// session bucket), catalog, and a map of concurrent session handles.
struct WorkspaceRuntime {
  cwd : String
  platform : @cetas_core.CetasPlatform
  catalog : &SessionCatalog
  handles : Map[String, SessionHandle]
  mut active_id : String
  mut permission_mode : @permission.PermissionMode
}

///|
struct WebRuntime {
  fs : &@workspace.WorkspaceFs
  home : String
  group : @async.TaskGroup[Unit]
  hub : EventHub
  workspaces : Map[String, WorkspaceRuntime]
  /// Registry cwds not yet composed; combined lazily on first switch.
  mut registry : Array[String]
  mut active_cwd : String
}

///|
fn permission_mode_name(mode : @permission.PermissionMode) -> String {
  match mode {
    ReadOnly => "readonly"
    WorkspaceWrite => "workspace_write"
    Interactive => "interactive"
    Auto => "auto"
    Yolo => "yolo"
  }
}

///|
fn WorkspaceRuntime::active(self : WorkspaceRuntime) -> SessionHandle {
  match self.handles.get(self.active_id) {
    Some(handle) => handle
    None => abort("cetas-web: active session handle missing")
  }
}

///|
fn unwrap_workspace(workspace : WorkspaceRuntime?) -> WorkspaceRuntime {
  match workspace {
    Some(found) => found
    None => abort("cetas-web: workspace handle missing")
  }
}

///|
fn emit_workspace_snapshot(
  workspace : WorkspaceRuntime,
  handle : SessionHandle,
) -> Unit {
  handle.observer.emit_snapshot(
    handle.model,
    handle.effort,
    workspace.cwd,
    handle.busy,
    permission_mode_name(handle.policy.mode),
  )
}

///|
fn WebRuntime::active(self : WebRuntime) -> WorkspaceRuntime {
  match self.workspaces.get(self.active_cwd) {
    Some(workspace) => workspace
    None => abort("cetas-web: active workspace missing")
  }
}

///|
fn emit_handle_snapshot(
  workspace : WorkspaceRuntime,
  handle : SessionHandle,
) -> Unit {
  handle.observer.emit_snapshot(
    handle.model,
    handle.effort,
    workspace.cwd,
    handle.busy,
    permission_mode_name(handle.policy.mode),
  )
}

///|
fn WebRuntime::emit_active_snapshot(self : WebRuntime) -> Unit {
  let workspace = self.active()
  emit_handle_snapshot(workspace, workspace.active())
}

///|
fn WebRuntime::runtime_json(self : WebRuntime) -> Json {
  let workspace = self.active()
  let handle = workspace.active()
  Json::object(
    Map::from_array([
      ("status", Json::string("ready")),
      ("session_id", Json::string(handle.session_id)),
      ("model", Json::string(handle.model)),
      ("effort", Json::string(handle.effort)),
      ("cwd", Json::string(workspace.cwd)),
      ("permission", Json::string(permission_mode_name(handle.policy.mode))),
      ("detail", Json::string("")),
    ]),
  )
}

///|
/// Resolve the target session: an explicit id composes a handle on demand in
/// the active workspace; without one, the workspace's active session runs.
async fn WebRuntime::resolve_handle(
  self : WebRuntime,
  session_id : String?,
) -> Result[SessionHandle, String] noraise {
  let workspace = self.active()
  match session_id {
    Some(id) =>
      match workspace.handles.get(id) {
        Some(handle) => Ok(handle)
        None => self.compose_handle(workspace, id)
      }
    None => Ok(workspace.active())
  }
}

///|
async fn WebRuntime::compose_handle(
  self : WebRuntime,
  workspace : WorkspaceRuntime,
  session_id : String,
) -> Result[SessionHandle, String] noraise {
  match workspace.catalog.check_id(session_id) {
    Err(reason) => return Err(reason)
    Ok(_) => ()
  }
  let handle = compose_session_agent(
    self.fs,
    self.home,
    workspace.cwd,
    self.group,
    workspace.platform,
    self.hub,
    workspace.permission_mode,
    session_id,
  ) catch {
    error => return Err(error.to_string())
  }
  workspace.handles[session_id] = handle
  Ok(handle)
}

///|
async fn WebRuntime::start_turn(
  self : WebRuntime,
  prompt : String,
  session_id : String?,
) -> Result[String, String] noraise {
  let handle = match self.resolve_handle(session_id) {
    Ok(handle) => handle
    Err(message) => return Err(message)
  }
  if handle.busy {
    return Err("a turn is already running in this session")
  }
  let prompt = prompt.trim().to_owned()
  if prompt.is_empty() {
    return Err("prompt must not be empty")
  }

  handle.turn_no += 1
  let turn_id = "t-" + handle.turn_no.to_string()
  handle.busy = true
  handle.observer.begin_turn(turn_id)
  handle.observer.emit_turn_accepted(prompt)

  let agent = handle.agent
  let sid = handle.session_id
  let workspace = self.workspaces.get(handle.cwd) |> unwrap_workspace
  self.group.spawn_bg(async fn() {
    let outcome : Result[String, @posoco.AgentError] = Ok(
      @cetas_core.run_prompt(agent, prompt, sid),
    ) catch {
      error => Err(error)
    }
    match outcome {
      Ok(text) => handle.observer.emit_turn_completed(text)
      Err(error) => handle.observer.emit_turn_failed(error.to_string())
    }
    handle.busy = false
    emit_workspace_snapshot(workspace, handle)
  })

  Ok(turn_id)
}

///|
async fn WebRuntime::abort_turn(
  self : WebRuntime,
  session_id : String?,
) -> Unit noraise {
  let handle = match self.resolve_handle(session_id) {
    Ok(handle) => handle
    Err(message) => {
      self.hub.emit("", "", "protocol.error", extra=[
        ("message", Json::string(message)),
      ])
      return
    }
  }
  let outcome = handle.agent.control().abort_active(None)
  handle.observer.emit_abort_result(outcome.to_string())
}

///|
/// Compose one agent bound to `session_id` over the workspace platform. The
/// agent itself is session-id agnostic; the id is chosen when turns run, so
/// switching sessions composes a fresh agent for the target id.
async fn compose_session_agent(
  fs : &@workspace.WorkspaceFs,
  home : String,
  cwd : String,
  group : @async.TaskGroup[Unit],
  platform : @cetas_core.CetasPlatform,
  hub : EventHub,
  permission_mode : @permission.PermissionMode,
  session_id : String,
) -> SessionHandle {
  let warn = async fn(text : String) noraise {
    @stdio.stderr.write("cetas-web: " + text) catch {
      _ => ()
    }
  }
  let feature_exts = build_compiled_recipe_features(
    ctx={ fs, cwd, home, },
    nmem_group=Some(group),
  )
  let session = @cetas_core.build_cetas_session(
    platform~,
    cwd~,
    feature_exts~,
    label="cetas-web",
    warn~,
  )
  session.permission.mode = permission_mode
  let router = session.router
  let policy = session.permission
  let observer = WebObserver::new(hub, session_id)
  let tail_exts : Array[&@posoco.Extension] = [observer as &@posoco.Extension]
  let agent = @cetas_core.compose_cetas_agent(
    session~,
    tail_exts~,
    runtime_group=Some(group),
  )
  {
    agent,
    session_id,
    cwd,
    observer,
    model: router.active_slot_id(),
    effort: router.active_effort().unwrap_or("default"),
    router,
    policy,
    busy: false,
    turn_no: 0,
  }
}

///|
async fn WebRuntime::switch_session(
  self : WebRuntime,
  session_id : String,
) -> Result[String, String] noraise {
  let workspace = self.active()
  if workspace.handles.get(session_id) is Some(handle) {
    workspace.active_id = session_id
    emit_handle_snapshot(workspace, handle)
    return Ok(session_id)
  }
  let handle = match self.compose_handle(workspace, session_id) {
    Ok(handle) => handle
    Err(message) => return Err(message)
  }
  workspace.active_id = session_id
  emit_handle_snapshot(workspace, handle)
  Ok(session_id)
}

///|
async fn WebRuntime::new_session(
  self : WebRuntime,
) -> Result[String, String] noraise {
  let session_id = @cetas_core.mint_session_id()
  self.switch_session(session_id)
}

///|
/// Switch the active workspace, composing its platform and first session on
/// first touch. Composition failures (bad cwd, broken recipe) surface as 409.
async fn WebRuntime::switch_workspace(
  self : WebRuntime,
  cwd : String,
) -> Result[String, String] noraise {
  let normalized = @fs_session.normalize_cwd(cwd)
  if self.workspaces.contains(normalized) {
    self.active_cwd = normalized
    self.emit_active_snapshot()
    return Ok(normalized)
  }
  let workspace = build_workspace(
    self.fs,
    self.home,
    normalized,
    self.group,
    self.hub,
    @permission.PermissionMode::WorkspaceWrite,
  ) catch {
    error => return Err(error.to_string())
  }
  self.workspaces[normalized] = workspace
  self.registry = self.registry.filter(registered => registered != normalized)
  self.sync_registry()
  self.active_cwd = normalized
  self.emit_active_snapshot()
  Ok(normalized)
}

///|
async fn WebRuntime::sync_registry(self : WebRuntime) -> Unit noraise {
  let cwds = self.registry.copy()
  for cwd, _ in self.workspaces {
    if !cwds.contains(cwd) {
      cwds.push(cwd)
    }
  }
  save_registry(self.home, cwds) catch {
    error =>
      @stdio.stderr.write("cetas-web: registry write failed: \{error}") catch {
        _ => ()
      }
  }
}

///|
fn WebRuntime::workspaces_json(self : WebRuntime) -> Json {
  let workspaces : Array[Json] = []
  for cwd in self.registry {
    if self.workspaces.contains(cwd) {
      continue
    }
    let name = match cwd.split("/").last() {
      Some(part) => part.to_owned()
      None => cwd
    }
    workspaces.push(
      Json::object(
        Map::from_array([
          ("cwd", Json::string(cwd)),
          ("name", Json::string(name)),
          ("active", Json::boolean(false)),
          ("active_session", Json::string("")),
        ]),
      ),
    )
  }
  for cwd, workspace in self.workspaces {
    let name = match cwd.split("/").last() {
      Some(part) => part.to_owned()
      None => cwd
    }
    workspaces.push(
      Json::object(
        Map::from_array([
          ("cwd", Json::string(cwd)),
          ("name", Json::string(name)),
          ("active", Json::boolean(cwd == self.active_cwd)),
          ("active_session", Json::string(workspace.active_id)),
        ]),
      ),
    )
  }
  Json::object(
    Map::from_array([
      ("active", Json::string(self.active_cwd)),
      ("workspaces", Json::array(workspaces)),
    ]),
  )
}

///|
async fn WebRuntime::persist_model_selection(
  self : WebRuntime,
  handle : SessionHandle,
) -> Unit noraise {
  let selection = @cetas_core.ActiveModelSelection::from_current(
    handle.model,
    handle.router.active_effort(),
  )
  @cetas_core.write_active_model_selection(self.fs, home=self.home, selection) catch {
    error =>
      @stdio.stderr.write("cetas-web: persist model selection failed: \{error}") catch {
        _ => ()
      }
  }
}

///|
async fn WebRuntime::switch_model(
  self : WebRuntime,
  slot_id : String,
  session_id : String?,
) -> Result[Unit, String] noraise {
  let handle = match self.resolve_handle(session_id) {
    Ok(handle) => handle
    Err(message) => return Err(message)
  }
  if handle.busy {
    return Err("a turn is already running in this session")
  }
  handle.router.switch_slot(slot_id) catch {
    error => return Err(error.to_string())
  }
  handle.model = slot_id
  handle.effort = handle.router.active_effort().unwrap_or("default")
  self.persist_model_selection(handle)
  self.emit_active_snapshot()
  Ok(())
}

///|
async fn WebRuntime::select_effort(
  self : WebRuntime,
  effort : String,
  session_id : String?,
) -> Result[Unit, String] noraise {
  let handle = match self.resolve_handle(session_id) {
    Ok(handle) => handle
    Err(message) => return Err(message)
  }
  if handle.busy {
    return Err("a turn is already running in this session")
  }
  handle.router.select_effort(handle.model, effort) catch {
    error => return Err(error.to_string())
  }
  handle.effort = effort
  self.persist_model_selection(handle)
  self.emit_active_snapshot()
  Ok(())
}

///|
fn WebRuntime::set_permission(
  self : WebRuntime,
  mode_name : String,
) -> Result[Unit, String] {
  let mode = match mode_name {
    "readonly" => @permission.PermissionMode::ReadOnly
    "workspace_write" => @permission.PermissionMode::WorkspaceWrite
    "yolo" => @permission.PermissionMode::Yolo
    "interactive" | "auto" =>
      return Err(
        "permission mode '\{mode_name}' needs the approval surface, which cetas-web has not wired yet",
      )
    other => return Err("unknown permission mode: \{other}")
  }
  let workspace = self.active()
  workspace.permission_mode = mode
  for _, handle in workspace.handles {
    handle.policy.mode = mode
  }
  self.emit_active_snapshot()
  Ok(())
}

///|
async fn WebRuntime::model_slots_json(
  self : WebRuntime,
  session_id : String?,
) -> Json noraise {
  let handle = match self.resolve_handle(session_id) {
    Ok(handle) => handle
    Err(_) => self.active().active()
  }
  let active_id = handle.model
  let slots : Array[Json] = []
  for slot in handle.router.list_slots() {
    let efforts : Array[Json] = []
    for effort in slot.thinking_efforts {
      efforts.push(Json::string(effort))
    }
    slots.push(
      Json::object(
        Map::from_array([
          ("id", Json::string(slot.id)),
          ("label", Json::string(slot.label)),
          ("provider", Json::string(slot.provider_id)),
          ("model", Json::string(slot.model_id)),
          ("active", Json::boolean(slot.id == active_id)),
          ("efforts", Json::array(efforts)),
          (
            "default_effort",
            match slot.default_effort {
              Some(effort) => Json::string(effort)
              None => Json::null()
            },
          ),
          (
            "group",
            match slot.display_group {
              Some(group) => Json::string(group)
              None => Json::null()
            },
          ),
          (
            "context_window",
            match slot.context_window {
              Some(window) => Json::number(window.to_double())
              None => Json::null()
            },
          ),
        ]),
      ),
    )
  }
  Json::object(
    Map::from_array([
      ("active", Json::string(active_id)),
      ("effort", Json::string(handle.effort)),
      ("permission", Json::string(permission_mode_name(handle.policy.mode))),
      ("slots", Json::array(slots)),
    ]),
  )
}

///|
async fn WebRuntime::sessions_json(self : WebRuntime) -> Json {
  let workspace = self.active()
  let active_id = workspace.active_id
  let sessions : Array[Json] = []
  let ids = workspace.catalog.list_ids()
  for index in 0..<ids.length() {
    let id = ids[ids.length() - 1 - index]
    let entry = workspace.catalog.entry(id) catch { _ => continue }
    sessions.push(
      Json::object(
        Map::from_array([
          ("id", Json::string(entry.id)),
          ("title", Json::string(entry.title)),
          ("active", Json::boolean(entry.id == active_id)),
        ]),
      ),
    )
  }
  Json::object(
    Map::from_array([
      ("active", Json::string(active_id)),
      ("cwd", Json::string(workspace.cwd)),
      ("sessions", Json::array(sessions)),
    ]),
  )
}

///|
/// Build one workspace runtime: platform, catalog, and the first session
/// handle. Failures propagate so a bad cwd never registers silently.
async fn build_workspace(
  fs : &@workspace.WorkspaceFs,
  home : String,
  cwd : String,
  group : @async.TaskGroup[Unit],
  hub : EventHub,
  permission_mode : @permission.PermissionMode,
) -> WorkspaceRuntime {
  let warn = async fn(text : String) noraise {
    @stdio.stderr.write("cetas-web: " + text) catch {
      _ => ()
    }
  }
  let platform = @cetas_core.build_cetas_platform(
    home~,
    cwd~,
    fs,
    permission_mode=@permission.PermissionMode::ReadOnly,
    mcp_group=Some(group),
    label="cetas-web",
    warn~,
  )
  let first_session_id = @cetas_core.mint_session_id()
  let observer = WebObserver::new(hub, first_session_id)
  let feature_exts = build_compiled_recipe_features(
    ctx={ fs, cwd, home, },
    nmem_group=Some(group),
  )
  let session = @cetas_core.build_cetas_session(
    platform~,
    cwd~,
    feature_exts~,
    label="cetas-web",
    warn~,
  )
  session.permission.mode = permission_mode
  let router = session.router
  let policy = session.permission
  let tail_exts : Array[&@posoco.Extension] = [observer as &@posoco.Extension]
  let agent = @cetas_core.compose_cetas_agent(
    session~,
    tail_exts~,
    runtime_group=Some(group),
  )
  let handle : SessionHandle = {
    agent,
    session_id: first_session_id,
    cwd,
    observer,
    model: router.active_slot_id(),
    effort: router.active_effort().unwrap_or("default"),
    router,
    policy,
    busy: false,
    turn_no: 0,
  }
  let handles : Map[String, SessionHandle] = Map::from_array([
    (first_session_id, handle),
  ])
  let catalog : &SessionCatalog = FsSessionCatalog::new(platform.session_store)
  {
    cwd,
    platform,
    catalog,
    handles,
    active_id: first_session_id,
    permission_mode,
  }
}

///|
async fn compose_web_runtime(
  home : String,
  cwd : String,
  group : @async.TaskGroup[Unit],
) -> WebRuntime {
  let fs_impl = @workspace.NativeWorkspaceFs()
  let fs : &@workspace.WorkspaceFs = fs_impl
  let hub = EventHub::new()
  let first = build_workspace(
    fs,
    home,
    cwd,
    group,
    hub,
    @permission.PermissionMode::WorkspaceWrite,
  )
  let workspaces : Map[String, WorkspaceRuntime] = Map::from_array([
    (cwd, first),
  ])
  let registry : Array[String] = load_registry(home) catch { _ => [] }
  let registry = registry.filter(registered => registered != cwd)
  { fs, home, group, hub, workspaces, registry, active_cwd: cwd, }
}
