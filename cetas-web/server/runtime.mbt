///|
struct ActiveSession {
  agent : @posoco.Agent
  session_id : String
  mut model : String
  mut effort : String
  router : @ext_llm.RouterModelPort
  policy : @permission.PermissionPolicy
}

///|
struct WebRuntime {
  fs : &@workspace.WorkspaceFs
  home : String
  cwd : String
  group : @async.TaskGroup[Unit]
  platform : @cetas_core.CetasPlatform
  catalog : &SessionCatalog
  observer : WebObserver
  mut active : ActiveSession
  mut busy : Bool
  mut turn_no : Int
  mut permission_mode : @permission.PermissionMode
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
fn WebRuntime::emit_snapshot(self : WebRuntime) -> Unit {
  self.observer.emit_snapshot(
    self.active.model,
    self.active.effort,
    self.cwd,
    self.busy,
    permission_mode_name(self.active.policy.mode),
  )
}

///|
fn WebRuntime::runtime_json(self : WebRuntime) -> Json {
  Json::object(
    Map::from_array([
      ("status", Json::string("ready")),
      ("session_id", Json::string(self.active.session_id)),
      ("model", Json::string(self.active.model)),
      ("effort", Json::string(self.active.effort)),
      ("cwd", Json::string(self.cwd)),
      (
        "permission",
        Json::string(permission_mode_name(self.active.policy.mode)),
      ),
      ("detail", Json::string("")),
    ]),
  )
}

///|
fn WebRuntime::start_turn(
  self : WebRuntime,
  prompt : String,
) -> Result[String, String] {
  if self.busy {
    return Err("a turn is already running")
  }
  let prompt = prompt.trim().to_owned()
  if prompt.is_empty() {
    return Err("prompt must not be empty")
  }

  self.turn_no += 1
  let turn_id = "t-" + self.turn_no.to_string()
  self.busy = true
  self.observer.begin_turn(turn_id)
  self.observer.emit_turn_accepted(prompt)

  let agent = self.active.agent
  let session_id = self.active.session_id
  self.group.spawn_bg(async fn() {
    let outcome : Result[String, @posoco.AgentError] = Ok(
      @cetas_core.run_prompt(agent, prompt, session_id),
    ) catch {
      error => Err(error)
    }
    match outcome {
      Ok(text) => self.observer.emit_turn_completed(text)
      Err(error) => self.observer.emit_turn_failed(error.to_string())
    }
    self.busy = false
    self.emit_snapshot()
  })

  Ok(turn_id)
}

///|
fn WebRuntime::abort_turn(self : WebRuntime) -> Unit {
  let outcome = self.active.agent.control().abort_active(None)
  self.observer.emit_abort_result(outcome.to_string())
}

///|
/// Compose one agent bound to `session_id` over the shared platform. The
/// agent itself is session-id agnostic; the id is chosen when turns run, so
/// switching sessions means composing a fresh agent for the target id.
async fn compose_session_agent(
  fs : &@workspace.WorkspaceFs,
  home : String,
  cwd : String,
  group : @async.TaskGroup[Unit],
  platform : @cetas_core.CetasPlatform,
  observer : WebObserver,
  permission_mode : @permission.PermissionMode,
  session_id : String,
) -> ActiveSession {
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
  let tail_exts : Array[&@posoco.Extension] = [observer as &@posoco.Extension]
  let agent = @cetas_core.compose_cetas_agent(
    session~,
    tail_exts~,
    runtime_group=Some(group),
  )
  {
    agent,
    session_id,
    model: router.active_slot_id(),
    effort: router.active_effort().unwrap_or("default"),
    router,
    policy,
  }
}

///|
async fn WebRuntime::switch_session(
  self : WebRuntime,
  session_id : String,
) -> Result[String, String] {
  if self.busy {
    return Err("a turn is already running")
  }
  match self.catalog.check_id(session_id) {
    Err(reason) => return Err(reason)
    Ok(_) => ()
  }
  if session_id == self.active.session_id {
    self.emit_snapshot()
    return Ok(session_id)
  }
  let composed : ActiveSession = compose_session_agent(
    self.fs,
    self.home,
    self.cwd,
    self.group,
    self.platform,
    self.observer,
    self.permission_mode,
    session_id,
  ) catch {
    error => return Err(error.to_string())
  }
  self.active = composed
  self.observer.session_id = session_id
  self.observer.turn_id = ""
  self.emit_snapshot()
  Ok(session_id)
}

///|
async fn WebRuntime::new_session(self : WebRuntime) -> Result[String, String] {
  let session_id = @cetas_core.mint_session_id()
  self.switch_session(session_id)
}

///|
async fn WebRuntime::persist_model_selection(self : WebRuntime) -> Unit {
  let selection = @cetas_core.ActiveModelSelection::from_current(
    self.active.model,
    self.active.router.active_effort(),
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
) -> Result[Unit, String] {
  if self.busy {
    return Err("a turn is already running")
  }
  self.active.router.switch_slot(slot_id) catch {
    error => return Err(error.to_string())
  }
  self.active.model = slot_id
  self.active.effort = self.active.router.active_effort().unwrap_or("default")
  self.persist_model_selection()
  self.emit_snapshot()
  Ok(())
}

///|
async fn WebRuntime::select_effort(
  self : WebRuntime,
  effort : String,
) -> Result[Unit, String] {
  if self.busy {
    return Err("a turn is already running")
  }
  self.active.router.select_effort(self.active.model, effort) catch {
    error => return Err(error.to_string())
  }
  self.active.effort = effort
  self.persist_model_selection()
  self.emit_snapshot()
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
  self.permission_mode = mode
  self.active.policy.mode = mode
  self.emit_snapshot()
  Ok(())
}

///|
fn WebRuntime::model_slots_json(self : WebRuntime) -> Json {
  let active_id = self.active.model
  let slots : Array[Json] = []
  for slot in self.active.router.list_slots() {
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
      ("effort", Json::string(self.active.effort)),
      (
        "permission",
        Json::string(permission_mode_name(self.active.policy.mode)),
      ),
      ("slots", Json::array(slots)),
    ]),
  )
}

///|
async fn WebRuntime::sessions_json(self : WebRuntime) -> Json {
  let active_id = self.active.session_id
  let sessions : Array[Json] = []
  let ids = self.catalog.list_ids()
  for index in 0..<ids.length() {
    let id = ids[ids.length() - 1 - index]
    let entry = self.catalog.entry(id) catch { _ => continue }
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
      ("cwd", Json::string(self.cwd)),
      ("sessions", Json::array(sessions)),
    ]),
  )
}

///|
async fn compose_web_runtime(
  home : String,
  cwd : String,
  group : @async.TaskGroup[Unit],
) -> WebRuntime {
  let fs_impl = @workspace.NativeWorkspaceFs()
  let fs : &@workspace.WorkspaceFs = fs_impl
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
  let observer = WebObserver::new("")
  // The first agent composes outside the struct literal so a composition
  // failure surfaces as the boot error instead of a panic.
  let first_session_id = @cetas_core.mint_session_id()
  let active = compose_session_agent(
    fs,
    home,
    cwd,
    group,
    platform,
    observer,
    @permission.PermissionMode::WorkspaceWrite,
    first_session_id,
  )
  observer.session_id = active.session_id
  let catalog : &SessionCatalog = FsSessionCatalog::new(platform.session_store)
  {
    fs,
    home,
    cwd,
    group,
    platform,
    catalog,
    observer,
    active,
    busy: false,
    turn_no: 0,
    permission_mode: @permission.PermissionMode::WorkspaceWrite,
  }
}
