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
fn NativeSessionState::switch_to(
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
  workspace_files : Array[String]
  mut skill_completion_items : Array[@ui.SelectItem]
  mut active_model : String
  mut active_effort : String?
}

///|
fn NativeHost::from_parts(
  agent : @posoco.Agent,
  shell : NativeShell,
  store : &@posoco.SessionStore,
  session_id : String,
  session_root? : String? = None,
  session_state? : NativeSessionState? = None,
  workspace_files? : Array[String] = [],
  skill_completion_items? : Array[@ui.SelectItem] = [],
  active_model? : String = "",
  active_effort? : String? = None,
) -> NativeHost {
  let session = match session_state {
    Some(value) => value
    None => NativeSessionState::new(session_id)
  }
  {
    agent,
    shell,
    store,
    session,
    session_root,
    workspace_files,
    skill_completion_items,
    active_model,
    active_effort,
  }
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

  let workspace_files = native_workspace_file_index(fs, cwd)

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
  let event_bus = @devkit.EventBus()
  let session = @cetas_core.build_cetas_session(
    platform~,
    cwd~,
    approval~,
    ui~,
    event_bus=Some(event_bus),
    bus_exts=Some(fn(bus) {
      [
        @statusbar.StatusBar(bus=Some(bus)) as &@posoco.Extension,
        @stats.Stats(bus=Some(bus)) as &@posoco.Extension,
      ]
    }),
    feature_exts~,
    label="cetas",
    warn~,
  )
  let subagent_observers : Array[(@subagent_kit.SubagentEvent) -> Unit] = []
  match ui {
    Some(port) =>
      subagent_observers.push(fn(event) {
        render_native_subagent_event(port, event)
      })
    None => ()
  }
  let subagents = build_cetas_subagents(
    parent_router=session.router,
    parent_mode=fn() { session.permission.mode() },
    approval~,
    ui~,
    observers=subagent_observers,
    context_fs=fs,
    feature_fs=fs,
    cwd~,
    home~,
  )
  let host_exts : Array[&@posoco.Extension] = [
    observer as &@posoco.Extension,
    subagents,
  ]
  for extension in tail_exts {
    host_exts.push(extension)
  }
  let agent = @cetas_core.compose_cetas_agent(session~, tail_exts=host_exts)
  let host = NativeHost::from_parts(
    agent,
    shell,
    session.session_store as &@posoco.SessionStore,
    sid,
    session_root=Some(session.session_store.root_dir),
    session_state=Some(session_state),
    workspace_files~,
    active_model=session.router.active_slot_id(),
    active_effort=session.router.active_effort(),
  )
  host.refresh_skill_completion_cache()
  host
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
/// Raw Agent handle for the executable's app-lifetime run_scoped owner.
/// Application turns still enter through NativeHost; this seam exists only
/// so the process can keep Posoco Tasks active for background subagents.
pub fn NativeHost::agent(self : NativeHost) -> @posoco.Agent {
  self.agent
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
fn NativeHost::switch_session(
  self : NativeHost,
  session_id : String,
) -> Result[Unit, String] {
  match @fs_session.validate_session_id(session_id) {
    Err(reason) => Err(reason)
    Ok(_) =>
      if self.session.switch_to(session_id) {
        Ok(())
      } else {
        Err("session id must not be empty")
      }
  }
}

///|
fn NativeHost::session_catalog(self : NativeHost) -> @posoco.CommandOutcome {
  guard self.session_root is Some(root) else {
    return @posoco.CommandOutcome::Failure(
      reason="native session directory is unavailable",
    )
  }
  let names = if @xfs.path_exists(root) {
    @xfs.read_dir(root) catch {
      @xfs.IOError::IOError(detail) =>
        return @posoco.CommandOutcome::Failure(
          reason="failed to list sessions: " + detail,
        )
    }
  } else {
    []
  }
  let ids : Array[String] = []
  for name in names {
    if !name.has_suffix(".jsonl") || name.length() <= 6 {
      continue
    }
    let path = if root.has_suffix("/") { root + name } else { root + "/" + name }
    let is_file = @xfs.is_file(path) catch { _ => false }
    if !is_file {
      continue
    }
    let id = name[:name.length() - 6].to_owned()
    match @fs_session.validate_session_id(id) {
      Ok(_) => ids.push(id)
      Err(_) => ()
    }
  }
  // Cetas-native session ids are clock-minted, so descending id order is
  // newest-first. Custom validator-clean ids remain deterministic.
  ids.sort()
  let entries : Array[Json] = []
  let current = self.session_id()
  let mut index = ids.length() - 1
  while index >= 0 {
    let id = ids[index]
    entries.push(
      Json::object(
        Map::from_array([
          ("id", Json::string(id)),
          ("current", Json::boolean(id == current)),
        ]),
      ),
    )
    index -= 1
  }
  @posoco.CommandOutcome::Success(
    feedback=ids.length().to_string() + " sessions",
    structured=Some(
      Json::object(
        Map::from_array([
          ("kind", Json::string("session_catalog")),
          ("sessions", Json::array(entries)),
        ]),
      ),
    ),
    ui_hint=None,
  )
}

///|
fn native_image_mime(path : String) -> String? {
  let lower = path.to_lower()
  if lower.has_suffix(".png") {
    Some("image/png")
  } else if lower.has_suffix(".jpg") || lower.has_suffix(".jpeg") {
    Some("image/jpeg")
  } else if lower.has_suffix(".gif") {
    Some("image/gif")
  } else if lower.has_suffix(".webp") {
    Some("image/webp")
  } else {
    None
  }
}

///|
fn native_trim_mention_token(token : String) -> String {
  let mut start = 0
  let mut end = token.length()
  while start < end &&
    (token[start] == '(' ||
    token[start] == '"' ||
    token[start] == '\'' ||
    token[start] == '{') {
    start += 1
  }
  while end > start {
    let ch = token[end - 1]
    if ch == ')' ||
      ch == '"' ||
      ch == '\'' ||
      ch == ']' ||
      ch == '}' ||
      ch == ',' ||
      ch == '.' ||
      ch == ':' ||
      ch == ';' ||
      ch == '!' ||
      ch == '?' {
      end -= 1
    } else {
      break
    }
  }
  token[start:end].to_owned()
}

///|
fn NativeHost::workspace_has_file(
  self : NativeHost,
  path : String,
) -> Bool {
  for item in self.workspace_files {
    if item == path {
      return true
    }
  }
  false
}

///|
/// Preserve the textual @path mention and append image blocks for workspace
/// image files. Like cetas-js, attachment failures are non-fatal: the prompt
/// still reaches the model and a transcript notice explains what was skipped.
fn NativeHost::user_message(
  self : NativeHost,
  prompt : String,
) -> @posoco.Message {
  let content : Array[@posoco.Content] = [@posoco.Content::Text(prompt)]
  let seen : Set[String] = Set([])
  for raw in prompt.split(" ") {
    if raw.length() <= 1 || raw[0] != '@' {
      continue
    }
    let path = native_trim_mention_token(raw[1:].to_owned())
    if path.is_empty() || seen.contains(path) || !self.workspace_has_file(path) {
      continue
    }
    guard native_image_mime(path) is Some(media_type) else { continue }
    seen.add(path)
    let bytes = @xfs.read_file_to_bytes(path) catch {
      @xfs.IOError::IOError(detail) => {
        ignore(
          self.shell.append_notice(
            "image attachment skipped @" + path + ": " + detail,
          ),
        )
        continue
      }
    }
    if bytes.length() > 5 * 1024 * 1024 {
      ignore(
        self.shell.append_notice(
          "image attachment skipped @" + path + ": file exceeds 5 MiB",
        ),
      )
      continue
    }
    content.push(
      @posoco.Content::Image(
        media_type~,
        data=@base64.encode(bytes[:]),
      ),
    )
  }
  @posoco.Message::UserMessage(content~)
}

///|
/// Start one fresh user turn. The user echo is committed before Posoco emits
/// TurnStarted; all later assistant/tool state arrives through the typed
/// NativeShellObserver installed during composition.
pub async fn NativeHost::run_text_turn(
  self : NativeHost,
  prompt : String,
) -> @posoco.TurnResult raise @posoco.AgentError {
  self.run_text_turn_with_echo(prompt, prompt)
}

///|
pub async fn NativeHost::run_text_turn_with_echo(
  self : NativeHost,
  prompt : String,
  display_prompt : String,
) -> @posoco.TurnResult raise @posoco.AgentError {
  ignore(self.shell.append_user(display_prompt))
  self.agent.run_turn(self.user_message(prompt), self.session.session_id())
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
    .enqueue_follow_up(self.user_message(prompt))
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
