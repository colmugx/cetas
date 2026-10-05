///|
struct WebRuntime {
  agent : @posoco.Agent
  observer : WebObserver
  session_id : String
  model : String
  effort : String
  cwd : String
  mut busy : Bool
  mut turn_no : Int
}

///|
fn WebRuntime::emit_snapshot(self : WebRuntime) -> Unit {
  self.observer.emit_snapshot(self.model, self.effort, self.cwd, self.busy)
}

///|
fn WebRuntime::start_turn(
  self : WebRuntime,
  group : @async.TaskGroup[Unit],
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

  group.spawn_bg(async fn() {
    let outcome : Result[String, @posoco.AgentError] = Ok(
      @cetas_core.run_prompt(self.agent, prompt, self.session_id),
    ) catch {
      error => Err(error)
    }
    match outcome {
      Ok(text) => self.observer.emit_turn_completed(text)
      Err(error) => self.observer.emit_turn_failed(error.to_string())
    }
    self.busy = false
  })

  Ok(turn_id)
}

///|
fn WebRuntime::abort_turn(self : WebRuntime) -> Unit {
  let outcome = self.agent.control().abort_active(None)
  self.observer.emit_abort_result(outcome.to_string())
}

///|
async fn compose_web_runtime(
  home : String,
  cwd : String,
  group : @async.TaskGroup[Unit],
) -> WebRuntime raise @posoco.CompositionError {
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
  let session_id = @cetas_core.mint_session_id()
  let observer = WebObserver::new(session_id)
  let tail_exts : Array[&@posoco.Extension] = [observer as &@posoco.Extension]
  let agent = @cetas_core.compose_cetas_agent(
    session~,
    tail_exts~,
    runtime_group=Some(group),
  )
  {
    agent,
    observer,
    session_id,
    model: session.router.active_slot_id(),
    effort: session.router.active_effort().unwrap_or("default"),
    cwd,
    busy: false,
    turn_no: 0,
  }
}
