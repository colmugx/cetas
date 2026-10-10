///|
/// Host identity handed to the console core by whichever adaptor composes
/// it: filesystem, cetas home, and the tags that attribute logs, status
/// registrations, and snapshot frames to the host.
pub struct ConsoleConfig {
  fs : &@workspace.WorkspaceFs
  home : String
  label : String
  protocol : String
}

///|
pub fn console_config(
  fs : &@workspace.WorkspaceFs,
  home : String,
  label : String,
  protocol : String,
) -> ConsoleConfig {
  { fs, home, label, protocol, }
}

///|
/// One running session: a composed agent plus its live turn state. Handles
/// run concurrently within a workspace; each owns its observer for event
/// attribution.
priv struct SessionHandle {
  agent : @posoco.Agent
  session_id : String
  cwd : String
  observer : ConsoleObserver
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
  zoo : Json
}

///|
pub struct ConsoleRuntime {
  fs : &@workspace.WorkspaceFs
  home : String
  label : String
  protocol : String
  group : @async.TaskGroup[Unit]
  hub : EventHub
  ui_registry : UiRegistry
  workspaces : Map[String, WorkspaceRuntime]
  /// Registry cwds not yet composed; combined lazily on first switch.
  mut registry : Array[String]
  mut active_cwd : String
  /// TTL-cached `@`-mention index for the active workspace: (built_at_ms,
  /// relative paths; directories carry a trailing `/`).
  mut file_index_cache : (Int64, Array[String])?
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
    None => abort("cetas-console: active session handle missing")
  }
}

///|
fn unwrap_workspace(workspace : WorkspaceRuntime?) -> WorkspaceRuntime {
  match workspace {
    Some(found) => found
    None => abort("cetas-console: workspace handle missing")
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
fn ConsoleRuntime::active(self : ConsoleRuntime) -> WorkspaceRuntime {
  match self.workspaces.get(self.active_cwd) {
    Some(workspace) => workspace
    None => abort("cetas-console: active workspace missing")
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
pub fn ConsoleRuntime::emit_active_snapshot(self : ConsoleRuntime) -> Unit {
  let workspace = self.active()
  emit_handle_snapshot(workspace, workspace.active())
}

///|
pub fn ConsoleRuntime::runtime_json(self : ConsoleRuntime) -> Json {
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
async fn ConsoleRuntime::resolve_handle(
  self : ConsoleRuntime,
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
async fn ConsoleRuntime::compose_handle(
  self : ConsoleRuntime,
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
    self.ui_registry,
    workspace.permission_mode,
    self.label,
    self.protocol,
    session_id,
  ) catch {
    error => return Err(error.to_string())
  }
  workspace.handles[session_id] = handle
  Ok(handle)
}

///|
fn collect_zoo(
  session_exts : Array[&@port.Extension],
  tail_exts : Array[&@posoco.Extension],
) -> Json {
  let all : Array[&@posoco.Extension] = []
  for ext in session_exts {
    all.push(ext)
  }
  for ext in tail_exts {
    all.push(ext)
  }
  Json::object(
    Map::from_array([("extensions", Json::array(ext_zoo_entries(all)))]),
  )
}

///|
pub async fn ConsoleRuntime::start_turn(
  self : ConsoleRuntime,
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
pub async fn ConsoleRuntime::abort_turn(
  self : ConsoleRuntime,
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
  ui_registry : UiRegistry,
  permission_mode : @permission.PermissionMode,
  label : String,
  protocol : String,
  session_id : String,
) -> SessionHandle {
  let warn = async fn(text : String) noraise {
    @stdio.stderr.write(label + ": " + text) catch {
      _ => ()
    }
  }
  let feature_exts = build_compiled_recipe_features(
    ctx={ fs, cwd, home, },
    nmem_group=Some(group),
  )
  let ui_port : &@posoco.UiPort = HubUiPort::new(hub, ui_registry, session_id)
  let approval : &@permission.ApprovalSource = UiBlockingApprovalSource::new(
    ui_port,
  )
  let session = @cetas_core.build_cetas_session(
    platform~,
    cwd~,
    feature_exts~,
    ui=Some(ui_port),
    approval=Some(approval),
    label~,
    warn~,
  )
  session.permission.mode = permission_mode
  let router = session.router
  let policy = session.permission
  let session_bus = session.event_bus
  let observer = ConsoleObserver::new(
    hub, session_bus, session_id, label, protocol,
  )
  let speed_metrics = @stats.Stats(bus=Some(session_bus))
  let statusbar = @statusbar.StatusBar(bus=Some(session_bus))
  seed_status(session_bus, label)
  let tail_exts : Array[&@posoco.Extension] = [
    observer as &@posoco.Extension,
    speed_metrics,
    statusbar,
  ]
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
pub async fn ConsoleRuntime::switch_session(
  self : ConsoleRuntime,
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
pub async fn ConsoleRuntime::new_session(
  self : ConsoleRuntime,
) -> Result[String, String] noraise {
  let session_id = @cetas_core.mint_session_id()
  self.switch_session(session_id)
}

///|
/// Switch the active workspace, composing its platform and first session on
/// first touch. Composition failures (bad cwd, broken recipe) surface as 409.
pub async fn ConsoleRuntime::switch_workspace(
  self : ConsoleRuntime,
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
    self.ui_registry,
    @permission.PermissionMode::WorkspaceWrite,
    self.label,
    self.protocol,
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
async fn ConsoleRuntime::sync_registry(self : ConsoleRuntime) -> Unit noraise {
  let cwds = self.registry.copy()
  for cwd, _ in self.workspaces {
    if !cwds.contains(cwd) {
      cwds.push(cwd)
    }
  }
  save_registry(self.home, cwds) catch {
    error =>
      @stdio.stderr.write(self.label + ": registry write failed: \{error}") catch {
        _ => ()
      }
  }
}

///|
pub fn ConsoleRuntime::workspaces_json(self : ConsoleRuntime) -> Json {
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
async fn ConsoleRuntime::persist_model_selection(
  self : ConsoleRuntime,
  handle : SessionHandle,
) -> Unit noraise {
  let selection = @cetas_core.ActiveModelSelection::from_current(
    handle.model,
    handle.router.active_effort(),
  )
  @cetas_core.write_active_model_selection(self.fs, home=self.home, selection) catch {
    error =>
      @stdio.stderr.write(
        self.label + ": persist model selection failed: \{error}",
      ) catch {
        _ => ()
      }
  }
}

///|
pub async fn ConsoleRuntime::switch_model(
  self : ConsoleRuntime,
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
pub async fn ConsoleRuntime::select_effort(
  self : ConsoleRuntime,
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
pub fn ConsoleRuntime::set_permission(
  self : ConsoleRuntime,
  mode_name : String,
) -> Result[Unit, String] {
  let mode = match mode_name {
    "readonly" => @permission.PermissionMode::ReadOnly
    "workspace_write" => @permission.PermissionMode::WorkspaceWrite
    "yolo" => @permission.PermissionMode::Yolo
    "interactive" => @permission.PermissionMode::Interactive
    "auto" =>
      return Err(
        "permission mode 'auto' needs a DecisionPort, which this console host has not composed",
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
pub async fn ConsoleRuntime::model_slots_json(
  self : ConsoleRuntime,
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
/// Re-push the active session's counters after a sink attaches: the
/// statusbar renders every valued segment on any segment op, so one update
/// delivers the full strip to the new connection.
pub fn ConsoleRuntime::republish_status(self : ConsoleRuntime) -> Unit {
  let handle = self.active().active()
  handle.observer.publish_turn_count()
  handle.observer.publish_step_count()
}

///|
pub fn ConsoleRuntime::zoo_json(self : ConsoleRuntime) -> Json {
  self.active().zoo
}

///|
pub async fn ConsoleRuntime::sessions_json(self : ConsoleRuntime) -> Json {
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
  ui_registry : UiRegistry,
  permission_mode : @permission.PermissionMode,
  label : String,
  protocol : String,
) -> WorkspaceRuntime {
  let warn = async fn(text : String) noraise {
    @stdio.stderr.write(label + ": " + text) catch {
      _ => ()
    }
  }
  let platform = @cetas_core.build_cetas_platform(
    home~,
    cwd~,
    fs,
    permission_mode=@permission.PermissionMode::ReadOnly,
    mcp_group=Some(group),
    label~,
    warn~,
  )
  let first_session_id = @cetas_core.mint_session_id()
  let ui_port : &@posoco.UiPort = HubUiPort::new(
    hub, ui_registry, first_session_id,
  )
  let approval : &@permission.ApprovalSource = UiBlockingApprovalSource::new(
    ui_port,
  )
  let feature_exts = build_compiled_recipe_features(
    ctx={ fs, cwd, home, },
    nmem_group=Some(group),
  )
  let session = @cetas_core.build_cetas_session(
    platform~,
    cwd~,
    feature_exts~,
    ui=Some(ui_port),
    approval=Some(approval),
    label~,
    warn~,
  )
  session.permission.mode = permission_mode
  let session_bus = session.event_bus
  let observer = ConsoleObserver::new(
    hub, session_bus, first_session_id, label, protocol,
  )
  let router = session.router
  let policy = session.permission
  let speed_metrics = @stats.Stats(bus=Some(session_bus))
  let statusbar = @statusbar.StatusBar(bus=Some(session_bus))
  seed_status(session_bus, label)
  let tail_exts : Array[&@posoco.Extension] = [
    observer as &@posoco.Extension,
    speed_metrics,
    statusbar,
  ]
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
  let zoo = collect_zoo(session.exts, tail_exts)
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
    zoo,
  }
}

///|
pub async fn compose_console_runtime(
  config : ConsoleConfig,
  cwd : String,
  group : @async.TaskGroup[Unit],
) -> ConsoleRuntime {
  let hub = EventHub::new()
  let ui_registry = UiRegistry::new()
  let first = build_workspace(
    config.fs,
    config.home,
    cwd,
    group,
    hub,
    ui_registry,
    @permission.PermissionMode::WorkspaceWrite,
    config.label,
    config.protocol,
  )
  let workspaces : Map[String, WorkspaceRuntime] = Map::from_array([
    (cwd, first),
  ])
  let registry : Array[String] = load_registry_with_legacy(config.home) catch {
    _ => []
  }
  let registry = registry.filter(registered => registered != cwd)
  {
    fs: config.fs,
    home: config.home,
    label: config.label,
    protocol: config.protocol,
    group,
    hub,
    ui_registry,
    workspaces,
    registry,
    active_cwd: cwd,
    file_index_cache: None,
  }
}

///|
/// `session.compact` — trigger the kernel compaction for the ACTIVE
/// session. Compaction is a long LLM call, so it runs in the runtime's
/// task group (the WS loop stays free for aborts) and its progress rides
/// the observer's `compact.started` / `compact.finished` events.
pub async fn ConsoleRuntime::compact_active_session(
  self : ConsoleRuntime,
) -> Unit {
  let handle = self.active().active()
  try {
    let outcome = handle.agent.compact_session(handle.session_id)
    println(
      self.label +
      ": compact finished final_session=\{outcome.final_session_id} messages_after=\{outcome.messages_after}",
    )
  } catch {
    error =>
      println(self.label + ": compact failed: \{@debug.to_string(error)}")
  }
}

///|
/// Trace page for the console UI: per-turn ledgers grouped request-side so
/// the trace stays a path of each answer instead of one wire dump.
pub fn ConsoleRuntime::trace_json(
  self : ConsoleRuntime,
  session_filter : String?,
  turn_filter : String?,
) -> Json {
  let turn_keys : Array[String] = match session_filter {
    Some(session) =>
      match self.hub.turn_order.get(session) {
        Some(order) => order
        None => []
      }
    None => {
      let all : Array[String] = []
      for _, order in self.hub.turn_order {
        for key in order {
          all.push(key)
        }
      }
      all
    }
  }
  let turns : Array[Json] = []
  let orphans : Array[Json] = []
  for index in 0..<turn_keys.length() {
    let key = turn_keys[turn_keys.length() - 1 - index]
    match self.hub.turn_traces.get(key) {
      Some(ledger) => {
        // key layout: "<session_id>/<turn_id>"; session ids never contain '/'
        // (validated), so the first '/' is the divider.
        let divider = key.find("/")
        let sid = match divider {
          Some(at) => key[:at].to_owned()
          None => key
        }
        let turn_part = match divider {
          Some(at) => key[at + 1:].to_owned()
          None => ""
        }
        if turn_part == "" {
          for event in ledger {
            orphans.push(event)
          }
        } else if session_filter is Some(want) && sid != want {
          continue
        } else if turn_filter is Some(want_turn) && turn_part != want_turn {
          continue
        } else {
          turns.push(
            Json::object(
              Map::from_array([
                ("turn_id", Json::string(turn_part)),
                ("session_id", Json::string(sid)),
                ("events", Json::array(ledger.copy())),
              ]),
            ),
          )
        }
      }
      None => ()
    }
  }
  Json::object(
    Map::from_array([
      ("turns", Json::array(turns)),
      ("orphans", Json::array(orphans)),
    ]),
  )
}

///|
/// Transcript replay for one session. A freshly minted session has no
/// transcript file yet; an unreadable one replays as empty, not as an error.
pub async fn ConsoleRuntime::transcript_json(
  self : ConsoleRuntime,
  session_id : String,
) -> Json {
  match self.active().catalog.check_id(session_id) {
    Err(_) => transcript_empty_json()
    Ok(_) =>
      try {
        let session = self.active().catalog.load(session_id)
        transcript_json(session)
      } catch {
        _ => transcript_empty_json()
      }
  }
}

///|
/// Rename one session in the active workspace catalog.
pub async fn ConsoleRuntime::rename_session(
  self : ConsoleRuntime,
  session_id : String,
  name : String,
) -> Result[Unit, String] {
  try {
    self.active().catalog.set_name(session_id, name)
    Ok(())
  } catch {
    error => Err(error.to_string())
  }
}

///|
/// Adaptor surface: one broadcast sink (the web keeps one WebSocket, the
/// desktop keeps one window emitter), event emission, UI-response resolve,
/// identity reads, and full shutdown.
pub fn ConsoleRuntime::attach_sink(
  self : ConsoleRuntime,
  sink : (String) -> Unit,
) -> Unit {
  self.hub.attach(sink)
}

///|
pub fn ConsoleRuntime::detach_sink(self : ConsoleRuntime) -> Unit {
  self.hub.detach()
}

///|
pub fn ConsoleRuntime::emit_event(
  self : ConsoleRuntime,
  session_id : String,
  turn_id : String,
  event_type : String,
  extra? : Array[(String, Json)] = [],
) -> Unit {
  self.hub.emit(session_id, turn_id, event_type, extra~)
}

///|
pub fn ConsoleRuntime::resolve_ui(
  self : ConsoleRuntime,
  request_id : String,
  response : String,
) -> Unit {
  self.ui_registry.resolve(request_id, response)
}

///|
pub fn ConsoleRuntime::active_session_id(self : ConsoleRuntime) -> String {
  self.active().active_id
}

///|
pub fn ConsoleRuntime::active_workspace(self : ConsoleRuntime) -> String {
  self.active_cwd
}

///|
pub async fn ConsoleRuntime::shutdown_all(self : ConsoleRuntime) -> Unit {
  for _, workspace in self.workspaces {
    for _, handle in workspace.handles {
      handle.agent.shutdown()
    }
  }
}
