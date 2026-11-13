///|
/// Host identity handed to the console core by whichever adaptor composes
/// it: filesystem, cetas home, and the tags that attribute logs, status
/// registrations, and snapshot frames to the host.
pub struct ConsoleConfig {
  fs : &@workspace.WorkspaceFs
  home : String
  label : String
  protocol : String
  /// Explicit opt-in for the native terminal host's realtime UI projection
  /// (tool lifecycle phases, argument deltas, `Custom` attribution, ledger
  /// facts and the unflattened `UiRender` shape). Off keeps every existing
  /// consumer on the shared wire contract.
  native_ui : Bool
  /// Host-resolved startup permission posture, stamped on the first workspace
  /// and on every workspace composed later. The shared default stays
  /// `WorkspaceWrite`; a host whose own policy differs (the native terminal
  /// resolves `Yolo`) states it here exactly once instead of the console
  /// hardcoding a second default per workspace.
  permission_mode : @permission.PermissionMode
  /// Opt-in for herdr presence reporting. A host that occupies a terminal
  /// pane (the native terminal) sets this; a server-style host (cetas-web)
  /// leaves it off, because a pane's agent rollup entry describes the
  /// foreground process, not a background server. Detection is still
  /// environment-gated, so the cost inside a non-herdr pane is one probe.
  herdr_presence : Bool
}

///|
pub fn console_config(
  fs : &@workspace.WorkspaceFs,
  home : String,
  label : String,
  protocol : String,
  native_ui~ : Bool = false,
  permission_mode~ : @permission.PermissionMode = @permission.PermissionMode::WorkspaceWrite,
  herdr_presence~ : Bool = false,
) -> ConsoleConfig {
  { fs, home, label, protocol, native_ui, permission_mode, herdr_presence, }
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
  mut turn_no : Int32
  /// The parent's `ask_question`/`notify_user` instance, held only under the
  /// native projection so an answer to a non-blocking question (delivered
  /// through the existing `resolve_ui` command, keyed by `question_id`) can
  /// reach the registry that parked it. `None` for the default console.
  questions : @askquestion.AskQuestionTools?
  /// This session's MCP bridge, held so `/mcp login` can drive the OAuth flow
  /// against the same connection set the agent runs on.
  mcp : @mcp.MCPToolBridge?
  /// Live background children of this session, fed by the subagent event
  /// stream. `None` when the delegation surface was never composed. A turn
  /// finishing does not finish its detached children, so `busy` alone cannot
  /// tell whether a handle is safe to retire.
  children : NativeChildMeter?
  /// Native session-lifetime scope owner: the close signal that lets
  /// `Agent::run_scoped` retire when the host shuts the session down. `None`
  /// when the projection is off or the scope could not be activated.
  close : @aqueue.Queue[Unit]?
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
  /// Native terminal UI projection opt-in, carried from `ConsoleConfig` to
  /// every session observer and UiPort this runtime composes.
  native_ui : Bool
  /// Host startup permission posture, carried from `ConsoleConfig`: the seed
  /// for the first workspace and every workspace composed on a later switch.
  /// Immutable — an interactive `/permission` switch only moves the live
  /// workspace, never this host policy.
  startup_permission : @permission.PermissionMode
  /// herdr presence opt-in, carried from `ConsoleConfig` to every workspace:
  /// a pane's agent state belongs to the process, so a workspace switch must
  /// not silently drop reporting.
  herdr_presence : Bool
  /// Host I/O task group (MCP connections, provider tool planes).
  group : @async.TaskGroup[Unit]
  /// Session-lifetime task group on posoco's core-async stack: the quota
  /// guard's recovery runtime (fuwaroid) runs here. `None` composes sessions
  /// without starting recovery.
  lifetime_group : @core_async.TaskGroup?
  hub : EventHub
  ui_registry : UiRegistry
  workspaces : Map[String, WorkspaceRuntime]
  /// Registry cwds not yet composed; combined lazily on first switch.
  mut registry : Array[String]
  mut active_cwd : String
  /// TTL-cached `@`-mention index for the active workspace: (built_at_ms,
  /// relative paths; directories carry a trailing `/`).
  mut file_index_cache : (Int64, Array[String])?
  /// Native-only bounded replay index cache (one compact line table per
  /// session revision). The default console never reads or writes it.
  replay_cache : NativeReplayCache
  /// Set by `shutdown_all` before it releases the existing session scopes.
  /// Composition that observes it releases its fresh handle instead of
  /// adding one nobody will signal again: posoco's `run_scoped` exits on the
  /// close signal, not on task cancellation, so a handle added after the
  /// sweep parks its scope owner forever and trips the async runtime's
  /// deadlock detector at task-group exit.
  mut stopping : Bool
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
/// Release one composed handle's session scope exactly the way `shutdown_all`
/// does: the close signal retires the parked `run_scoped` owner, or a
/// scope-less agent shuts down directly.
async fn release_handle_scope(handle : SessionHandle) -> Unit {
  match handle.close {
    Some(close) => ignore(close.try_put(()) catch { _ => false })
    None => handle.agent.shutdown()
  }
}

///|
async fn ConsoleRuntime::compose_handle(
  self : ConsoleRuntime,
  workspace : WorkspaceRuntime,
  session_id : String,
) -> Result[SessionHandle, String] noraise {
  // Fast refusal: never start a fresh composition once the shutdown sweep
  // has begun (the mid-compose window is handled after the protected region).
  if self.stopping {
    return Err("runtime is shutting down")
  }
  match workspace.catalog.check_id(session_id) {
    Err(reason) => return Err(reason)
    Ok(_) => ()
  }
  // Composition suspends on disk I/O, so a shutdown can land mid-compose:
  // `shutdown_all` may already have swept the workspace's handles. Protect
  // the compose-and-decide region, then either install the handle or — once
  // stopping — release the fresh scope instead of parking it on a close
  // signal nobody will ever send.
  let handle : Result[SessionHandle, String] = @async.protect_from_cancel(async fn() {
    Ok(
      compose_session_agent(
        self.fs,
        self.home,
        workspace.cwd,
        self.group,
        self.lifetime_group,
        workspace.platform,
        self.hub,
        self.ui_registry,
        workspace.permission_mode,
        self.label,
        self.protocol,
        self.native_ui,
        self.herdr_presence,
        session_id,
      ),
    ) catch {
      error => Err(error.to_string())
    }
  }) catch {
    error => return Err(error.to_string())
  }
  match handle {
    Ok(handle) => {
      if self.stopping {
        release_handle_scope(handle) catch {
          _ => ()
        }
        return Err("runtime is shutting down")
      }
      workspace.handles[session_id] = handle
      Ok(handle)
    }
    Err(reason) => Err(reason)
  }
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
  images~ : Array[@posoco.Content] = [],
) -> Result[String, String] noraise {
  let handle = match self.resolve_handle(session_id) {
    Ok(handle) => handle
    Err(message) => return Err(message)
  }
  if handle.busy {
    return Err("a turn is already running in this session")
  }
  let prompt = prompt.trim().to_owned()
  if prompt.is_empty() && images.is_empty() {
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
    // Shutdown may arrive before this accepted turn enters the Agent.
    // Do not admit it after the serving-lifetime session scope is released.
    if self.stopping {
      handle.observer.emit_turn_failed("runtime is shutting down")
      handle.busy = false
      return
    }
    let outcome : Result[String, @posoco.AgentError] = Ok(
      @cetas_core.run_prompt(agent, prompt, sid, images~),
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
  lifetime_group : @core_async.TaskGroup?,
  platform : @cetas_core.CetasPlatform,
  hub : EventHub,
  ui_registry : UiRegistry,
  permission_mode : @permission.PermissionMode,
  label : String,
  protocol : String,
  native_ui : Bool,
  herdr_presence : Bool,
  session_id : String,
) -> SessionHandle {
  let warn = async fn(text : String) noraise {
    if native_ui {
      hub.native_warning(session_id, text)
    } else {
      @stdio.stderr.write(label + ": " + text) catch {
        _ => ()
      }
    }
  }
  let ui_port : &@posoco.UiPort = HubUiPort::new(
    hub,
    ui_registry,
    session_id,
    native_ui~,
  )
  let approval : &@permission.ApprovalSource = UiBlockingApprovalSource::new(
    ui_port,
  )
  // Native only: hold the parent question instance so its lifecycle reaches
  // the terminal and the existing answer command can settle it.
  let questions = native_question_tools(hub, session_id, native_ui~)
  let feature_exts = build_compiled_recipe_features(
    ctx={ fs, cwd, home, },
    host_group=Some(group),
    askquestion=questions,
  )
  let plan_review = ConsolePlanReview::ConsolePlanReview(ui_port)
  let session = @cetas_core.build_cetas_session(
    platform~,
    cwd~,
    feature_exts~,
    ui=Some(ui_port),
    approval=Some(approval),
    tool_plane_group=Some(group),
    // Plan mode publishes its tool exemptions at construction, so it must be
    // built after the permission gate subscribes.
    events_exts=Some(fn(events) {
      [compose_plan_mode(events, plan_review, fs, cwd) as &@posoco.Extension]
    }),
    label~,
    warn~,
  )
  session.permission.mode = permission_mode
  let router = session.router
  let policy = session.permission
  // The observer publishes the harness counters as typed status ops on the
  // session channel, under its own host-label owner.
  let observer = ConsoleObserver::new(
    hub,
    @cetas_core.mint_events_publisher(session.events, owner=label),
    session_id,
    protocol,
    native_ui~,
  )
  // The speed metrics publish their typed ops on the session event system the
  // bar below listens on.
  let speed_metrics = @stats.Stats()
  let statusbar = @statusbar.StatusBar(events=Some(session.events))
  seed_status(@cetas_core.mint_events_publisher(session.events, owner=label))
  let tail_exts : Array[&@posoco.Extension] = [
    observer as &@posoco.Extension,
    speed_metrics,
    statusbar,
  ]
  // herdr presence: this session's turn events drive the pane's agent state.
  // Detection is environment-gated, so a non-herdr pane registers nothing.
  if herdr_presence {
    match @herdr.HerdrReporter::detect() {
      Some(reporter) => tail_exts.push(reporter as &@posoco.Extension)
      None => ()
    }
  }
  // Native only: the real delegation surface, with child events forwarded to
  // this session's sink. The default console never composes it.
  let mut children : NativeChildMeter? = None
  match native_subagent_sink(hub, session_id, native_ui~) {
    Some(sink) => {
      let meter : NativeChildMeter = { live: Map::from_array([]), }
      tail_exts.push(
        compose_native_subagents(
          fs,
          home,
          cwd,
          group,
          ui_port,
          approval,
          router,
          fn() { policy.mode() },
          observers=[sink, fn(event) { meter.observe(event) }],
        ),
      )
      children = Some(meter)
    }
    None => ()
  }
  // MCP joins as a tail extension: its live tools arrive after the session's
  // routing capture, so the static catalog stays free of duplicates.
  let mcp_bridge = compose_mcp_bridge(
    fs, home, cwd, group, lifetime_group, label,
  )
  tail_exts.push(mcp_bridge as &@posoco.Extension)
  reserve_mcp_tool_names(mcp_bridge, session.base_defs)
  let agent = @cetas_core.compose_cetas_agent(
    session~,
    tail_exts~,
    runtime=Some(
      compose_mcp_runtime(mcp_bridge, router as &@posoco.ModelPort)
      as &@runtime.Runtime,
    ),
    runtime_group=lifetime_group,
  )
  let close = native_session_scope(group, agent, native_ui~, label)
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
    questions,
    mcp: Some(mcp_bridge),
    children,
    close,
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
    self.retire_idle_handles(workspace)
    return Ok(session_id)
  }
  let handle = match self.compose_handle(workspace, session_id) {
    Ok(handle) => handle
    Err(message) => return Err(message)
  }
  workspace.active_id = session_id
  emit_handle_snapshot(workspace, handle)
  self.retire_idle_handles(workspace)
  Ok(session_id)
}

///|
/// Hard ceiling on retained session handles per workspace. Sessions are
/// journaled, so a retired handle recomposes from disk on demand; the ceiling
/// bounds agent/context retention across long `/new` sequences without
/// touching any live work.
const MAX_RETAINED_SESSION_HANDLES : Int32 = 8

///|
/// Pure retirement predicate, split from the handle so every guard is testable
/// without composing an agent that has a parked question. A handle may only be
/// dropped when no turn is running, no question is open or undelivered, and no
/// detached child is still live.
fn handle_retirable(
  busy : Bool,
  questions_open : Int32,
  questions_undelivered : Bool,
  children_live : Int32,
) -> Bool {
  !busy && questions_open == 0 && !questions_undelivered && children_live == 0
}

///|
fn session_handle_retirable(handle : SessionHandle) -> Bool {
  let questions_open = match handle.questions {
    Some(tools) => tools.open_questions().length()
    None => 0
  }
  let questions_undelivered = match handle.questions {
    Some(tools) => tools.has_undelivered()
    None => false
  }
  let children_live = match handle.children {
    Some(meter) => meter.live_count()
    None => 0
  }
  handle_retirable(
    handle.busy,
    questions_open,
    questions_undelivered,
    children_live,
  )
}

///|
/// Retire idle non-active handles above the retention ceiling. Retirement is
/// the same scope release `shutdown_all` performs — the parked `run_scoped`
/// owner, not a racing `shutdown` call, owns the agent's teardown — and the
/// retired session stays resumable: its journal is on disk and a later switch
/// recomposes the handle. The active session and every handle with live work
/// are always kept.
async fn ConsoleRuntime::retire_idle_handles(
  self : ConsoleRuntime,
  workspace : WorkspaceRuntime,
) -> Unit noraise {
  if self.stopping || workspace.handles.length() <= MAX_RETAINED_SESSION_HANDLES {
    return
  }
  let victims : Array[String] = []
  for id, handle in workspace.handles {
    if workspace.handles.length() - victims.length() <=
      MAX_RETAINED_SESSION_HANDLES {
      break
    }
    if id == workspace.active_id {
      continue
    }
    if session_handle_retirable(handle) {
      victims.push(id)
    }
  }
  for id in victims {
    match workspace.handles.get(id) {
      Some(handle) => {
        release_handle_scope(handle) catch {
          _ => ()
        }
        workspace.handles.remove(id)
      }
      None => ()
    }
  }
}

///|
pub async fn ConsoleRuntime::new_session(
  self : ConsoleRuntime,
) -> Result[String, String] noraise {
  let session_id = @cetas_core.mint_session_id()
  self.switch_session(session_id)
}

///|
/// Release every session scope of a freshly built workspace that lost the
/// shutdown race: same hand-off as `shutdown_all`, applied to a workspace
/// that was never installed.
async fn release_workspace_scopes(workspace : WorkspaceRuntime) -> Unit {
  for _, handle in workspace.handles {
    release_handle_scope(handle)
  }
}

///|
/// Switch the active workspace, composing its platform and first session on
/// first touch. Composition failures (bad cwd, broken recipe) surface as 409.
pub async fn ConsoleRuntime::switch_workspace(
  self : ConsoleRuntime,
  cwd : String,
) -> Result[String, String] noraise {
  if self.stopping {
    return Err("runtime is shutting down")
  }
  let normalized = @fs_session.normalize_cwd(cwd)
  if self.workspaces.contains(normalized) {
    self.active_cwd = normalized
    self.emit_active_snapshot()
    return Ok(normalized)
  }
  let workspace : Result[WorkspaceRuntime, String] = @async.protect_from_cancel(async fn() {
      Ok(
        build_workspace(
          self.fs,
          self.home,
          normalized,
          self.group,
          self.lifetime_group,
          self.hub,
          self.ui_registry,
          self.startup_permission,
          self.label,
          self.protocol,
          self.native_ui,
          self.herdr_presence,
        ),
      ) catch {
        error => Err(error.to_string())
      }
    },
  ) catch {
    error => return Err(error.to_string())
  }
  match workspace {
    Err(reason) => Err(reason)
    Ok(workspace) => {
      // A shutdown that swept during the build must not strand the fresh
      // workspace's parked scopes: release and refuse instead of installing.
      if self.stopping {
        release_workspace_scopes(workspace) catch {
          _ => ()
        }
        return Err("runtime is shutting down")
      }
      self.workspaces[normalized] = workspace
      self.registry = self.registry.filter(registered => {
        registered != normalized
      })
      self.sync_registry()
      self.active_cwd = normalized
      self.emit_active_snapshot()
      Ok(normalized)
    }
  }
}

///|
/// Atomic cross-workspace resume. The target workspace and its session handle
/// are located or composed first; only when both exist does the active
/// workspace move, so a failure leaves the caller's workspace and session
/// exactly as they were. `permission` seeds a workspace this process has never
/// opened — an already-open workspace keeps the permission it has, and no
/// switch ever widens an inherited narrowed mode by accident. Background work
/// in the previous workspace keeps running; nothing is torn down.
pub async fn ConsoleRuntime::resume_workspace_session(
  self : ConsoleRuntime,
  cwd : String,
  session_id : String,
  permission : String?,
) -> Result[String, String] noraise {
  if self.stopping {
    return Err("runtime is shutting down")
  }
  let normalized = @fs_session.normalize_cwd(cwd)
  let workspace = match self.workspaces.get(normalized) {
    Some(workspace) => workspace
    None => {
      let mode = match permission {
        Some(name) =>
          match parse_permission_mode(name) {
            Ok(mode) => mode
            Err(reason) => return Err(reason)
          }
        None => self.startup_permission
      }
      let built : Result[WorkspaceRuntime, String] = @async.protect_from_cancel(async fn() {
          Ok(
            build_workspace(
              self.fs,
              self.home,
              normalized,
              self.group,
              self.lifetime_group,
              self.hub,
              self.ui_registry,
              mode,
              self.label,
              self.protocol,
              self.native_ui,
              self.herdr_presence,
            ),
          ) catch {
            error => Err(error.to_string())
          }
        },
      ) catch {
        error => return Err(error.to_string())
      }
      match built {
        Err(reason) => return Err(reason)
        Ok(workspace) => {
          // Same shutdown hand-off as switch_workspace: never install a
          // workspace whose scopes the sweep can no longer reach.
          if self.stopping {
            release_workspace_scopes(workspace) catch {
              _ => ()
            }
            return Err("runtime is shutting down")
          }
          workspace
        }
      }
    }
  }
  let handle = match workspace.handles.get(session_id) {
    Some(handle) => handle
    None =>
      match self.compose_handle(workspace, session_id) {
        Ok(handle) => handle
        Err(reason) => return Err(reason)
      }
  }
  workspace.active_id = session_id
  self.workspaces[normalized] = workspace
  self.registry = self.registry.filter(registered => registered != normalized)
  self.sync_registry()
  self.active_cwd = normalized
  emit_handle_snapshot(workspace, handle)
  self.retire_idle_handles(workspace)
  Ok(session_id)
}

///|
/// Compose one session's agent handle without activating it, so a later
/// `switch_session` to the same id answers from the handle cache instead of
/// composing on the interactive path. Additive for every host: no events are
/// emitted and neither the active workspace nor the active session moves.
pub async fn ConsoleRuntime::prefetch_session(
  self : ConsoleRuntime,
  session_id : String,
) -> Result[String, String] noraise {
  let workspace = self.active()
  if workspace.handles.get(session_id) is Some(_) {
    return Ok(session_id)
  }
  match self.compose_handle(workspace, session_id) {
    Ok(_) => Ok(session_id)
    Err(reason) => Err(reason)
  }
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
      if self.native_ui {
        self.hub.native_warning("", "registry write failed: \{error}")
      } else {
        @stdio.stderr.write(self.label + ": registry write failed: \{error}") catch {
          _ => ()
        }
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
      if self.native_ui {
        self.hub.native_warning(
          handle.session_id,
          "persist model selection failed: \{error}",
        )
      } else {
        @stdio.stderr.write(
          self.label + ": persist model selection failed: \{error}",
        ) catch {
          _ => ()
        }
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
  let mode = match parse_permission_mode(mode_name) {
    Ok(mode) => mode
    Err(reason) => return Err(reason)
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
/// Parse a wire permission name. `auto` needs a DecisionPort this console
/// host has not composed, so it is rejected like an unknown name.
fn parse_permission_mode(
  mode_name : String,
) -> Result[@permission.PermissionMode, String] {
  match mode_name {
    "readonly" => Ok(@permission.PermissionMode::ReadOnly)
    "workspace_write" => Ok(@permission.PermissionMode::WorkspaceWrite)
    "yolo" => Ok(@permission.PermissionMode::Yolo)
    "interactive" => Ok(@permission.PermissionMode::Interactive)
    "auto" =>
      Err(
        "permission mode 'auto' needs a DecisionPort, which this console host has not composed",
      )
    other => Err("unknown permission mode: \{other}")
  }
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
  handle.router.refresh_model_metadata()
  for slot in handle.router.list_slots() {
    let window = handle.router.context_window_reading(slot)
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
          ("context_window", Json::number(window.tokens.to_double())),
          ("context_window_source", Json::string(window.source)),
          ("context_window_stale", Json::boolean(window.stale)),
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
/// Native picker metadata only; shared sessions_json keeps its existing shape.
pub async fn ConsoleRuntime::session_catalog_json(
  self : ConsoleRuntime,
  scope : String,
  after : String,
  limit : Int32,
) -> Json {
  if !self.native_ui {
    return replay_error("session_catalog is native-only")
  }
  native_session_catalog_json(
    self.home,
    self.active_cwd,
    self.active().active_id,
    scope,
    after,
    limit,
  )
}

///|
pub async fn ConsoleRuntime::sessions_json(self : ConsoleRuntime) -> Json {
  let workspace = self.active()
  let active_id = workspace.active_id
  let sessions : Array[Json] = []
  let ids = workspace.catalog.list_ids()
  for index in 0..<ids.length() {
    let id = ids[ids.length() - 1 - index]
    if self.native_ui {
      // Native path: the title comes from the metadata line plus the legacy
      // first-user line, streamed. `entry` (store.summary -> store.load) would
      // materialise every listed session, which is exactly the long-session
      // cost this seam removes.
      let path = match workspace.catalog.transcript_path(id) {
        Ok(path) => path
        Err(_) => continue
      }
      let title = match native_replay_title(id, path) {
        Ok(title) => title
        Err(_) => continue
      }
      sessions.push(
        Json::object(
          Map::from_array([
            ("id", Json::string(id)),
            ("title", Json::string(title)),
            ("active", Json::boolean(id == active_id)),
          ]),
        ),
      )
    } else {
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
  lifetime_group : @core_async.TaskGroup?,
  hub : EventHub,
  ui_registry : UiRegistry,
  permission_mode : @permission.PermissionMode,
  label : String,
  protocol : String,
  native_ui : Bool,
  herdr_presence : Bool,
) -> WorkspaceRuntime {
  let warn = async fn(text : String) noraise {
    if native_ui {
      hub.native_warning("", text)
    } else {
      @stdio.stderr.write(label + ": " + text) catch {
        _ => ()
      }
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
    hub,
    ui_registry,
    first_session_id,
    native_ui~,
  )
  let approval : &@permission.ApprovalSource = UiBlockingApprovalSource::new(
    ui_port,
  )
  let questions = native_question_tools(hub, first_session_id, native_ui~)
  let mut first_children : NativeChildMeter? = None
  let feature_exts = build_compiled_recipe_features(
    ctx={ fs, cwd, home, },
    host_group=Some(group),
    askquestion=questions,
  )
  let plan_review = ConsolePlanReview::ConsolePlanReview(ui_port)
  let session = @cetas_core.build_cetas_session(
    platform~,
    cwd~,
    feature_exts~,
    ui=Some(ui_port),
    approval=Some(approval),
    tool_plane_group=Some(group),
    // Plan mode publishes its tool exemptions at construction, so it must be
    // built after the permission gate subscribes.
    events_exts=Some(fn(events) {
      [compose_plan_mode(events, plan_review, fs, cwd) as &@posoco.Extension]
    }),
    label~,
    warn~,
  )
  session.permission.mode = permission_mode
  let observer = ConsoleObserver::new(
    hub,
    @cetas_core.mint_events_publisher(session.events, owner=label),
    first_session_id,
    protocol,
    native_ui~,
  )
  let router = session.router
  let policy = session.permission
  // The speed metrics publish their typed ops on the session event system the
  // bar listens on.
  let speed_metrics = @stats.Stats()
  let statusbar = @statusbar.StatusBar(events=Some(session.events))
  seed_status(@cetas_core.mint_events_publisher(session.events, owner=label))
  let tail_exts : Array[&@posoco.Extension] = [
    observer as &@posoco.Extension,
    speed_metrics,
    statusbar,
  ]
  // herdr presence: this session's turn events drive the pane's agent state.
  // Detection is environment-gated, so a non-herdr pane registers nothing.
  if herdr_presence {
    match @herdr.HerdrReporter::detect() {
      Some(reporter) => tail_exts.push(reporter as &@posoco.Extension)
      None => ()
    }
  }
  match native_subagent_sink(hub, first_session_id, native_ui~) {
    Some(sink) => {
      let meter : NativeChildMeter = { live: Map::from_array([]), }
      tail_exts.push(
        compose_native_subagents(
          fs,
          home,
          cwd,
          group,
          ui_port,
          approval,
          router,
          fn() { policy.mode() },
          observers=[sink, fn(event) { meter.observe(event) }],
        ),
      )
      first_children = Some(meter)
    }
    None => ()
  }
  // MCP joins as a tail extension: its live tools arrive after the session's
  // routing capture, so the static catalog stays free of duplicates.
  let mcp_bridge = compose_mcp_bridge(
    fs, home, cwd, group, lifetime_group, label,
  )
  tail_exts.push(mcp_bridge as &@posoco.Extension)
  reserve_mcp_tool_names(mcp_bridge, session.base_defs)
  let agent = @cetas_core.compose_cetas_agent(
    session~,
    tail_exts~,
    runtime=Some(
      compose_mcp_runtime(mcp_bridge, router as &@posoco.ModelPort)
      as &@runtime.Runtime,
    ),
    runtime_group=lifetime_group,
  )
  let close = native_session_scope(group, agent, native_ui~, label)
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
    questions,
    mcp: Some(mcp_bridge),
    children: first_children,
    close,
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
  lifetime_group~ : @core_async.TaskGroup? = None,
) -> ConsoleRuntime {
  let hub = EventHub::new()
  if config.native_ui {
    hub.enable_native_retention()
  }
  let ui_registry = UiRegistry::new()
  let first = build_workspace(
    config.fs,
    config.home,
    cwd,
    group,
    lifetime_group,
    hub,
    ui_registry,
    config.permission_mode,
    config.label,
    config.protocol,
    config.native_ui,
    config.herdr_presence,
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
    native_ui: config.native_ui,
    startup_permission: config.permission_mode,
    herdr_presence: config.herdr_presence,
    group,
    lifetime_group,
    hub,
    ui_registry,
    workspaces,
    registry,
    active_cwd: cwd,
    file_index_cache: None,
    replay_cache: NativeReplayCache::new(),
    stopping: false,
  }
}

///|
/// Drop this host's herdr pane authority. Needed by exits that never reach an
/// Agent shutdown: a composition that failed after detection registered the
/// pane leaves no Lifecycle behind to release it, and herdr would keep showing
/// an agent for a process that is gone. Environment-gated like detection, so
/// outside a managed pane this is a no-op.
pub fn release_herdr_presence() -> Unit {
  match @herdr.HerdrReporter::from_env() {
    Some(reporter) => reporter.release()
    None => ()
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
          let fields = Map::from_array([
            ("turn_id", Json::string(turn_part)),
            ("session_id", Json::string(sid)),
            ("events", Json::array(ledger.copy())),
          ])
          if self.native_ui {
            fields["retention"] = self.hub.turn_retention_json(key)
          }
          turns.push(Json::object(fields))
        }
      }
      None => ()
    }
  }
  let fields = Map::from_array([
    ("turns", Json::array(turns)),
    ("orphans", Json::array(orphans)),
  ])
  if self.native_ui {
    fields["retention"] = self.hub.retention_json()
  }
  Json::object(fields)
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
/// Native-only bounded index of one session's transcript: revision, absolute
/// projected block total, context state, and a light metadata window (defaults
/// to the tail so resume starts near the end of the journal). No bodies.
pub async fn ConsoleRuntime::transcript_index_json(
  self : ConsoleRuntime,
  session_id : String,
  first~ : Int32 = -1,
  limit~ : Int32 = 0,
) -> Json {
  if !self.native_ui {
    return replay_error(
      "transcript_index is native-only (native_ui projection)",
    )
  }
  match self.active().catalog.transcript_path(session_id) {
    Err(reason) => replay_error(reason)
    Ok(path) =>
      native_replay_index_json(
        self.replay_cache,
        session_id,
        path,
        first,
        limit,
      )
  }
}

///|
/// Native-only bounded transcript page: seeks to the journal line holding
/// `first` and streams forward. Items keep the existing transcript item schema
/// with absolute `index`es; oversized bodies become previews plus refs served
/// by `transcript_source`.
pub async fn ConsoleRuntime::transcript_page_json(
  self : ConsoleRuntime,
  session_id : String,
  revision : String,
  first : Int32,
  limit : Int32,
  max_bytes : Int32,
) -> Json {
  if !self.native_ui {
    return replay_error("transcript_page is native-only (native_ui projection)")
  }
  match self.active().catalog.transcript_path(session_id) {
    Err(reason) => replay_error(reason)
    Ok(path) =>
      native_replay_page_json(
        self.replay_cache,
        session_id,
        path,
        revision,
        first,
        limit,
        max_bytes,
      )
  }
}

///|
/// Native-only range read of one block's decoded payload, for the refs a page
/// emits instead of giant bodies. Chunks are capped below the host frame limit.
pub async fn ConsoleRuntime::transcript_source_json(
  self : ConsoleRuntime,
  session_id : String,
  revision : String,
  index : Int32,
  field~ : String = "",
  offset~ : Int32 = 0,
  length~ : Int32 = 0,
) -> Json {
  if !self.native_ui {
    return replay_error(
      "transcript_source is native-only (native_ui projection)",
    )
  }
  match self.active().catalog.transcript_path(session_id) {
    Err(reason) => replay_error(reason)
    Ok(path) =>
      native_replay_source_json(
        self.replay_cache,
        session_id,
        path,
        revision,
        index,
        field,
        offset,
        length,
      )
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
/// Run one console action on the runtime's task group instead of the caller's
/// loop.
///
/// Long actions that wait on the host (`ConsoleRuntime::login` parks on a
/// `ui.request` until `resolve_ui` answers it) must not be awaited by a
/// command loop: the loop is what delivers that answer, so awaiting in place
/// would deadlock. The action reports its own result through the event hub,
/// exactly as a turn reports through its observer.
pub fn ConsoleRuntime::spawn_background(
  self : ConsoleRuntime,
  task : async () -> Unit,
) -> Unit {
  self.group.spawn_bg(task)
}

///|
pub fn ConsoleRuntime::emit_event(
  self : ConsoleRuntime,
  session_id : String,
  turn_id : String,
  event_type : String,
  extra~ : Array[(String, Json)] = [],
) -> Unit {
  self.hub.emit(session_id, turn_id, event_type, extra~)
}

///|
/// Fan one host-level lifecycle fact to the attached sink only: it enters
/// neither the rolling wire log nor any session ledger. Completion events
/// for host-initiated commands (async session switching) are terminal host
/// facts, not transcript rows, so out-of-band is the exact channel.
pub fn ConsoleRuntime::emit_host_event(
  self : ConsoleRuntime,
  session_id : String,
  event_type : String,
  extra~ : Array[(String, Json)] = [],
) -> Unit {
  self.hub.emit_out_of_band(session_id, event_type, extra~)
}

///|
/// Adaptor surface: settle one UI request by id. Blocking asks (approvals,
/// `ask_question`, OAuth prompts) wait in the `UiRegistry`. Under the native
/// projection a non-blocking question (`notify_user`) is keyed by its
/// `question_id` instead, so the very same command settles it — no second
/// response route. Question ids never collide with `u-<n>` request ids, and an
/// unmatched id stays the no-op it always was.
pub fn ConsoleRuntime::resolve_ui(
  self : ConsoleRuntime,
  request_id : String,
  response : String,
) -> Unit {
  self.ui_registry.resolve(request_id, response)
  if !self.native_ui {
    return
  }
  for _, workspace in self.workspaces {
    for _, handle in workspace.handles {
      match handle.questions {
        Some(questions) =>
          if native_answer_question(questions, request_id, response) {
            return
          }
        None => ()
      }
    }
  }
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
  // Fence FIRST: composition in flight must observe stopping when its
  // protected region ends, release its fresh scope, and refuse the install —
  // a handle added after this sweep would park on a close signal that no
  // second sweep will ever send.
  self.stopping = true
  for _, workspace in self.workspaces {
    for _, handle in workspace.handles {
      // A pending or active turn must be interrupted before its session
      // scope is released, otherwise the task group may never drain.
      if handle.busy {
        ignore(handle.agent.control().abort_active(None))
      }
      // Native sessions own exactly one `run_scoped`, and that scope is the
      // Agent's shutdown owner: releasing it makes `run_scoped` retire the
      // Agent itself (task runtime, wakeup pump, lifecycle shutdown). Calling
      // `shutdown` here as well would race it, so the signal is the whole
      // hand-off. The host task group drains the parked owner on exit.
      release_handle_scope(handle)
    }
  }
}
