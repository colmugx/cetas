/// Native Cetas application host.
///
/// This is the composition seam that replaces cetas-js host.ts. It owns the
/// real Posoco Agent and persisted session handle, while NativeShell owns
/// terminal-facing semantic state. NativeShellObserver is installed directly
/// as an Agent extension, so production TurnEvent flow never needs the JSON
/// migration wire.

///|
pub struct NativeHost {
  agent : @posoco.Agent
  shell : NativeShell
  store : &@posoco.SessionStore
  session_id : String
}

///|
fn NativeHost::from_parts(
  agent : @posoco.Agent,
  shell : NativeShell,
  store : &@posoco.SessionStore,
  session_id : String,
) -> NativeHost {
  { agent, shell, store, session_id }
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
    label="cetas-native",
    warn~,
  )

  let shell = NativeShell::new()
  let observer = NativeShellObserver::new(shell)
  let session = @cetas_core.build_cetas_session(
    platform~,
    cwd~,
    approval~,
    ui~,
    label="cetas-native",
    warn~,
  )
  let agent = @cetas_core.compose_cetas_agent(
    session~,
    tail_exts=[observer as &@posoco.Extension],
  )
  let sid = if session_id.is_empty() {
    @cetas_core.mint_session_id()
  } else {
    session_id
  }

  NativeHost::from_parts(
    agent,
    shell,
    session.session_store as &@posoco.SessionStore,
    sid,
  )
}

///|
pub fn NativeHost::shell(self : NativeHost) -> NativeShell {
  self.shell
}

///|
pub fn NativeHost::session_id(self : NativeHost) -> String {
  self.session_id
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
    self.session_id,
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
  let outcome = self.agent.control().enqueue_follow_up(
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
/// Rewind the current persisted session through the shared cetas-core helper.
///
/// Busy-state policy belongs to the higher shell/application command layer;
/// this method is the storage capability itself.
pub async fn NativeHost::rewind(
  self : NativeHost,
  from_index : Int,
) -> Unit raise @posoco.SessionError {
  @cetas_core.rewind_session(self.store, self.session_id, from_index)
}

///|
pub async fn NativeHost::shutdown(self : NativeHost) -> Unit {
  self.agent.shutdown()
}
