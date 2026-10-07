/// Full-path native GPUI host core. This is a normal MoonBit async executable;
/// Cargo intercepts Moon's final C link and embeds the generated program.

///|
struct DesktopRuntime {
  agent : @posoco.Agent
  router : @ext_llm.RouterModelPort
  policy : @permission.PermissionPolicy
  group : @async.TaskGroup[Unit]
  observer : DesktopObserver
  session_id : String
  cwd : String
  mut busy : Bool
  mut turn_no : Int
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
fn DesktopRuntime::emit_snapshot(self : DesktopRuntime) -> Unit {
  self.observer.emit_snapshot(
    self.router.active_slot_id(),
    self.router.active_effort().unwrap_or("default"),
    self.cwd,
    self.busy,
    permission_mode_name(self.policy.mode),
  )
}

///|
fn DesktopRuntime::start_turn(
  self : DesktopRuntime,
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
  self.observer.emit("turn.accepted", extra=[
    ("prompt", Json::string(prompt)),
  ])
  self.emit_snapshot()

  let agent = self.agent
  let session_id = self.session_id
  self.group.spawn_bg(async fn() {
    let outcome : Result[String, @posoco.AgentError] = Ok(
      @cetas_core.run_prompt(agent, prompt, session_id),
    ) catch {
      error => Err(error)
    }
    match outcome {
      Ok(text) =>
        self.observer.emit("turn.completed", extra=[
          ("text", Json::string(text)),
        ])
      Err(error) =>
        self.observer.emit("turn.failed", extra=[
          ("message", Json::string(error.to_string())),
        ])
    }
    self.busy = false
    self.emit_snapshot()
  })

  Ok(turn_id)
}

///|
fn DesktopRuntime::abort_turn(self : DesktopRuntime) -> Unit {
  let outcome = self.agent.control().abort_active(None)
  self.observer.emit("turn.abort_result", extra=[
    ("outcome", Json::string(outcome.to_string())),
  ])
}

///|
async fn compose_desktop_runtime(
  home : String,
  cwd : String,
  group : @async.TaskGroup[Unit],
) -> DesktopRuntime {
  let fs_impl = @workspace.NativeWorkspaceFs()
  let fs : &@workspace.WorkspaceFs = fs_impl
  let warn = async fn(text : String) noraise {
    bridge_emit_json(
      Json::object(
        Map::from_array([
          ("type", Json::string("core.warning")),
          ("message", Json::string(text)),
        ]),
      ),
    )
  }
  let platform = @cetas_core.build_cetas_platform(
    home~,
    cwd~,
    fs,
    permission_mode=@permission.PermissionMode::ReadOnly,
    mcp_group=Some(group),
    label="cetas-gpui",
    warn~,
  )
  let feature_exts = build_compiled_recipe_features(
    ctx={ fs, cwd, home, },
    nmem_group=Some(group),
  )
  let session = @cetas_core.build_cetas_session(
    platform~,
    cwd~,
    feature_exts~,
    label="cetas-gpui",
    warn~,
  )
  session.permission.mode = @permission.PermissionMode::WorkspaceWrite

  let observer = DesktopObserver::new(@cetas_core.mint_session_id())
  let tail_exts : Array[&@posoco.Extension] = [
    observer as &@posoco.Extension,
  ]
  let agent = @cetas_core.compose_cetas_agent(
    session~,
    tail_exts~,
    runtime_group=Some(group),
  )

  {
    agent,
    router: session.router,
    policy: session.permission,
    group,
    observer,
    session_id: observer.session_id,
    cwd,
    busy: false,
    turn_no: 0,
  }
}

///|
fn decode_command(raw : String) -> (String, String) {
  let parsed = @json.parse(raw) catch {
    _ => return ("invalid", "command is not valid JSON")
  }
  guard parsed is Json::Object(fields) else {
    return ("invalid", "command must be a JSON object")
  }
  let kind = match fields.get("type") {
    Some(Json::String(value)) => value
    _ => return ("invalid", "command.type must be a string")
  }
  let value = match fields.get("prompt") {
    Some(Json::String(text)) => text
    _ => ""
  }
  (kind, value)
}

///|
async fn main {
  let home = @cetas_core.cetas_home()
  let cwd = @env.current_dir().unwrap_or(".")

  @async.with_task_group(group => {
    let boot : Result[DesktopRuntime, String] = Ok(
      compose_desktop_runtime(home, cwd, group),
    ) catch {
      error => Err(error.to_string())
    }

    match boot {
      Err(message) =>
        bridge_emit_json(
          Json::object(
            Map::from_array([
              ("type", Json::string("runtime.unavailable")),
              ("message", Json::string(message)),
            ]),
          ),
        )
      Ok(runtime) => {
        runtime.observer.emit("core.ready", extra=[
          ("protocol", Json::string("cetas-gpui/0.1")),
        ])
        runtime.emit_snapshot()

        let mut running = true
        while running {
          match bridge_take_command() {
            None => @async.sleep(8)
            Some(raw) => {
              let (kind, value) = decode_command(raw)
              match kind {
                "turn.start" =>
                  match runtime.start_turn(value) {
                    Ok(_) => ()
                    Err(message) =>
                      runtime.observer.emit("protocol.error", extra=[
                        ("message", Json::string(message)),
                      ])
                  }
                "turn.abort" => runtime.abort_turn()
                "shutdown" => running = false
                _ =>
                  runtime.observer.emit("protocol.error", extra=[
                    ("message", Json::string(value)),
                  ])
              }
            }
          }
        }
        runtime.agent.shutdown()
      }
    }
  })
}
