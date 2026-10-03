/// Native Cetas application host.
///
/// This is the composition seam that replaces cetas-js host.ts. It owns the
/// real Posoco Agent and persisted session handle, while NativeShell owns
/// terminal-facing semantic state. NativeShellObserver is installed directly
/// as an Agent extension, so production TurnEvent flow never needs the JSON
/// migration wire.

///|
pub struct NativeSessionState {
  mut session_id : String
}

///|
pub fn NativeSessionState::new(session_id : String) -> NativeSessionState {
  { session_id, }
}

///|
pub fn NativeSessionState::session_id(self : NativeSessionState) -> String {
  self.session_id
}

///|
/// Runtime redirects are authoritative facts from the active Agent turn.
/// They deliberately bypass user-intent busy guards, matching cetas-js.
pub fn NativeSessionState::adopt_redirect(
  self : NativeSessionState,
  to : String,
) -> Bool {
  if to.is_empty() {
    return false
  }
  self.session_id = to
  true
}

///|
pub struct NativeHost {
  agent : @posoco.Agent
  shell : NativeShell
  store : &@posoco.SessionStore
  session : NativeSessionState
  session_root : String?
  active_model : String
  active_effort : String?
}

///|
fn NativeHost::from_parts(
  agent : @posoco.Agent,
  shell : NativeShell,
  store : &@posoco.SessionStore,
  session_id : String,
  session_root? : String? = None,
  session_state? : NativeSessionState? = None,
  active_model? : String = "",
  active_effort? : String? = None,
) -> NativeHost {
  let session = match session_state {
    Some(value) => value
    None => NativeSessionState::new(session_id)
  }
  { agent, shell, store, session, session_root, active_model, active_effort, }
}

///|
/// Compose the production native host over the same cetas-core platform and
/// session assembly used by the other Cetas hosts.
///
/// Approval/UI ports are injectable so the native terminal presentation can be
/// wired without moving product policy into this host. Passing neither keeps
/// those optional capabilities absent, which is useful while the native ask
/// surface is still migrating.
pub async fn NativeHost::compose(
  home~ : String,
  cwd~ : String,
  mode~ : @permission.PermissionMode,
  approval? : &@permission.ApprovalSource? = None,
  ui? : &@posoco.UiPort? = None,
  tail_exts? : Array[&@posoco.Extension] = [],
  session_id? : String = "",
  fs? : &@workspace.WorkspaceFs? = None,
  mcp_group? : @async.TaskGroup[Unit]? = None,
  warn? : async (String) -> Unit noraise = fn(_ : String) { () },
) -> NativeHost raise @posoco.CompositionError {
  let fs : &@workspace.WorkspaceFs = match fs {
    Some(value) => value
    None => @workspace.NativeWorkspaceFs()
  }

  let platform = @cetas_core.build_cetas_platform(
    home~,
    cwd~,
    fs,
    permission_mode=mode,
    mcp_group~,
    label="cetas",
    warn~,
  )

  let sid = if session_id.is_empty() {
    @cetas_core.mint_session_id()
  } else {
    session_id
  }
  let session_state = NativeSessionState::new(sid)
  let shell = NativeShell::new()
  let observer = NativeShellObserver::new(
    shell,
    session_state=Some(session_state),
  )
  let feature_exts = build_compiled_recipe_features(
    ctx={ fs, cwd, home, },
    nmem_group=mcp_group,
  )
  let session = @cetas_core.build_cetas_session(
    platform~,
    cwd~,
    approval~,
    ui~,
    feature_exts~,
    label="cetas",
    warn~,
  )
  let host_exts : Array[&@posoco.Extension] = [observer as &@posoco.Extension]
  for extension in tail_exts {
    host_exts.push(extension)
  }
  let agent = @cetas_core.compose_cetas_agent(session~, tail_exts=host_exts)
  NativeHost::from_parts(
    agent,
    shell,
    session.session_store as &@posoco.SessionStore,
    sid,
    session_root=Some(session.session_store.root_dir),
    session_state=Some(session_state),
    active_model=session.router.active_slot_id(),
    active_effort=session.router.active_effort(),
  )
}

///|
/// Compose the production interactive native host.
///
/// The returned NativeUiPort is the terminal loop's pull/respond seam. The
/// approval source is intentionally filled by NativeUiBridge during Agent
/// composition so permission asks ride Posoco's composed UiPort wrapper.
pub async fn NativeHost::compose_interactive(
  home~ : String,
  cwd~ : String,
  mode~ : @permission.PermissionMode,
  session_id? : String = "",
  fs? : &@workspace.WorkspaceFs? = None,
  mcp_group? : @async.TaskGroup[Unit]? = None,
  warn? : async (String) -> Unit noraise = fn(_ : String) { () },
) -> (NativeHost, NativeUiPort) raise @posoco.CompositionError {
  let ui = NativeUiPort::new()
  let approval = NativeApprovalSource::new()
  let bridge = NativeUiBridge::new(approval)
  let host = NativeHost::compose(
    home~,
    cwd~,
    mode~,
    approval=Some(approval as &@permission.ApprovalSource),
    ui=Some(ui as &@posoco.UiPort),
    tail_exts=[bridge as &@posoco.Extension],
    session_id~,
    fs~,
    mcp_group~,
    warn~,
  )
  (host, ui)
}

///|
pub fn NativeHost::shell(self : NativeHost) -> NativeShell {
  self.shell
}

///|
pub fn NativeHost::session_id(self : NativeHost) -> String {
  self.session.session_id()
}

///|
pub fn NativeHost::active_model(self : NativeHost) -> String {
  self.active_model
}

///|
pub fn NativeHost::active_effort(self : NativeHost) -> String? {
  self.active_effort
}

///|
/// Start one fresh user turn. The user echo is committed before Posoco emits
/// TurnStarted; all later assistant/tool state arrives through the typed
/// NativeShellObserver installed during composition.
pub async fn NativeHost::run_text_turn(
  self : NativeHost,
  prompt : String,
) -> @posoco.TurnResult raise @posoco.AgentError {
  ignore(self.shell.append_user(prompt))
  self.agent.run_turn(
    @posoco.Message::UserMessage(content=[@posoco.Content::Text(prompt)]),
    self.session.session_id(),
  )
}

///|
/// Queue a follow-up on the active run.
///
/// Only an accepted AgentControl enqueue creates the visible queued transcript
/// bubble. Rejected stale/full/failure outcomes leave UI state untouched.
pub fn NativeHost::queue_follow_up(
  self : NativeHost,
  prompt : String,
) -> @runtime.EnqueueOutcome {
  let outcome = self.agent
    .control()
    .enqueue_follow_up(
      @posoco.Message::UserMessage(content=[@posoco.Content::Text(prompt)]),
    )
  match outcome {
    @runtime.Accepted(..) => ignore(self.shell.queue_follow_up(prompt))
    _ => ()
  }
  outcome
}

///|
/// Request cancellation of the currently active run.
///
/// The shell interruption flag is armed only when the Agent accepted the abort
/// (or had already accepted one). A stale request must not fabricate an
/// interrupted termination notice for an idle host.
pub fn NativeHost::interrupt_active(
  self : NativeHost,
) -> @runtime.EnqueueOutcome {
  let outcome = self.agent.control().abort_active(None)
  match outcome {
    @runtime.Accepted(..) | @runtime.AbortAlreadyRequested =>
      self.shell.request_interrupt()
    _ => ()
  }
  outcome
}

///|
fn NativeHost::read_persisted_jsonl(
  self : NativeHost,
) -> String raise @posoco.SessionError {
  guard self.session_root is Some(root) else {
    raise @posoco.SessionError::Load(
      "native host: persisted JSONL root is unavailable",
    )
  }
  match @fs_session.validate_session_id(self.session.session_id()) {
    Ok(_) => ()
    Err(reason) => raise @posoco.SessionError::Load("jsonl: " + reason)
  }
  let path = @fs_session.jsonl_session_path(root, self.session.session_id())
  if !@xfs.path_exists(path) {
    return ""
  }
  @xfs.read_file_to_string(path) catch {
    @xfs.IOError::IOError(detail) =>
      raise @posoco.SessionError::Load(
        "jsonl: failed to read " + path + ": " + detail,
      )
  }
}

///|
/// Enumerate native rewind targets from persisted JSONL physical lines.
///
/// This deliberately bypasses parsed Session.messages so malformed/blank
/// physical lines cannot shift truncate addresses.
pub fn NativeHost::rewind_points(
  self : NativeHost,
) -> Array[@cetas_core.PersistedRewindPoint] raise @posoco.SessionError {
  @cetas_core.list_persisted_rewind_points(self.read_persisted_jsonl())
}

///|
/// Read the full persisted user text at one physical-line rewind address.
pub fn NativeHost::rewind_user_message(
  self : NativeHost,
  message_index : Int,
) -> String? raise @posoco.SessionError {
  @cetas_core.read_persisted_rewind_user_message(
    self.read_persisted_jsonl(),
    message_index,
  )
}

///|
/// Rewind the current persisted session through the shared cetas-core helper.
///
/// Busy-state policy belongs to the higher shell/application command layer;
/// this method is the storage capability itself.
pub async fn NativeHost::rewind(
  self : NativeHost,
  from_index : Int,
) -> Unit raise @posoco.SessionError {
  @cetas_core.rewind_session(self.store, self.session.session_id(), from_index)
}

///|
pub async fn NativeHost::shutdown(self : NativeHost) -> Unit {
  self.agent.shutdown()
}
