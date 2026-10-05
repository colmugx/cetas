/// Product-level native terminal loop.
///
/// NativeAppLoop joins NativeTurnDriver and NativeRuntime without collapsing
/// their boundaries. Agent work runs in a child task; terminal polling is
/// non-blocking; one tick applies input semantics, flushes immutable
/// scrollback, and paints the latest live snapshot.

///|
pub(all) enum NativeLoopSignal {
  LoopContinue
  LoopExit
  LoopOpenRewind
  LoopApplyRewind(Int)
  LoopDismissOverlay
  LoopAutocomplete
  LoopToggleThinking
  LoopToggleToolOutput
  LoopLogin(String)
  LoopTerminalFailed(Int)
} derive(Eq)

///|
pub extend NativeLoopSignal with Eq::{equal, not_equal}

///|
pub struct NativeAppLoop {
  driver : NativeTurnDriver
  runtime : NativeRuntime
  editor : @ui.EditorModel
  rewind : @ui.RewindPickerModel
  mut compact_pending : Bool
  command_lock : CommandLockModel
  mut command_task : @async.Task[@posoco.CommandOutcome]?
  mut command_name : String?
  mut dismissible_overlay_visible : Bool
}

///|
pub fn NativeAppLoop::new(
  host : NativeHost,
  ui : NativeUiPort,
  terminal : @ui.Terminal,
) -> NativeAppLoop {
  let shell = host.shell()
  let editor = @ui.EditorModel::new()
  let controller = NativeUiController::new(ui)
  let router = NativeInputRouter::new(controller)
  let rewind = @ui.RewindPickerModel::new()
  let runtime = NativeRuntime::new(terminal, shell, router, editor, rewind)
  let driver = NativeTurnDriver::new(host, editor)
  {
    driver,
    runtime,
    editor,
    rewind,
    compact_pending: false,
    command_lock: CommandLockModel::new(),
    command_task: None,
    command_name: None,
    dismissible_overlay_visible: false,
  }
}

///|
pub fn NativeAppLoop::editor(self : NativeAppLoop) -> @ui.EditorModel {
  self.editor
}

///|
pub fn NativeAppLoop::is_turn_running(self : NativeAppLoop) -> Bool {
  self.driver.is_running()
}

///|
pub fn NativeAppLoop::session_id(self : NativeAppLoop) -> String {
  self.driver.host().session_id()
}

///|
/// Surface application-level failures through the transcript while the TUI
/// owns the terminal. Stderr is reserved for failures after terminal teardown.
pub fn NativeAppLoop::append_error(
  self : NativeAppLoop,
  message : String,
) -> Int {
  self.driver.host().shell().append_error(message)
}

///|
pub fn NativeAppLoop::append_notice(
  self : NativeAppLoop,
  message : String,
) -> Int {
  self.driver.host().shell().append_notice(message)
}

///|
pub fn NativeAppLoop::set_compact_pending(
  self : NativeAppLoop,
  value : Bool,
) -> Unit {
  self.compact_pending = value
}

///|
pub fn NativeAppLoop::command_busy(self : NativeAppLoop) -> Bool {
  self.command_lock.is_held()
}

///|
pub fn NativeAppLoop::command_label(self : NativeAppLoop) -> String? {
  self.command_lock.label()
}

///|
pub fn NativeAppLoop::auth_ui(self : NativeAppLoop) -> NativeAuthUi {
  self.runtime.auth_ui()
}

///|
/// Acquire/re-arm the command gate, matching cetas-js CommandLock.
///
/// Repeated acquire is intentional: auth/login flows may re-arm while a
/// picker already owns the gate. This is not a reference-counted lock.
pub fn NativeAppLoop::acquire_command(
  self : NativeAppLoop,
  label : String,
) -> Unit {
  self.command_lock.acquire(label)
  self.editor.set_submit_disabled(true)
}

///|
/// Release the command gate once. Duplicate releases are no-ops.
pub fn NativeAppLoop::release_command(self : NativeAppLoop) -> Bool {
  let released = self.command_lock.release()
  if released {
    self.editor.set_submit_disabled(false)
  }
  released
}

///|
/// Compatibility seam for callers still expressed as a busy boolean.
pub fn NativeAppLoop::set_command_busy(
  self : NativeAppLoop,
  value : Bool,
) -> Unit {
  if value {
    self.acquire_command("")
  } else {
    ignore(self.release_command())
  }
}

///|
pub fn NativeAppLoop::set_dismissible_overlay_visible(
  self : NativeAppLoop,
  value : Bool,
) -> Unit {
  self.dismissible_overlay_visible = value
}

///|
/// Resolve physical JSONL rewind targets and mount the picker.
///
/// False means there is nothing rewindable; this matches the picker reducer's
/// empty-source close behavior and leaves the editor focused.
pub fn NativeAppLoop::open_rewind(
  self : NativeAppLoop,
) -> Bool raise @posoco.SessionError {
  self.runtime.close_autocomplete()
  let points : Array[@ui.RewindPoint] = []
  for point in self.driver.host().rewind_points() {
    points.push({ message_index: point.message_index, preview: point.preview, })
  }
  self.rewind.open(points)
}

///|
/// Apply one picked physical-line address and refill the original prompt.
///
/// The full user text is captured before truncate because the selected user
/// row itself is the first row removed by SessionStore::truncate.
pub async fn NativeAppLoop::apply_rewind(
  self : NativeAppLoop,
  message_index : Int,
) -> Unit raise @posoco.SessionError {
  let host = self.driver.host()
  let refill = host.rewind_user_message(message_index)
  host.rewind(message_index)
  match refill {
    Some(text) => self.editor.set_text(text)
    None => self.editor.clear()
  }
  ignore(
    host
    .shell()
    .append_notice(
      "rewound to message #" +
      message_index.to_string() +
      " — the original prompt is back in the editor",
    ),
  )
}

///|
fn NativeAppLoop::runtime_state(self : NativeAppLoop) -> RuntimeInputState {
  {
    now_ms: @async.now().reinterpret_as_uint64(),
    editor_has_text: !self.editor.text().is_empty(),
    in_turn: self.driver.is_running(),
    compact_pending: self.compact_pending,
    command_busy: self.command_lock.is_held(),
    dismissible_overlay_visible: self.dismissible_overlay_visible,
  }
}

///|
fn NativeAppLoop::refresh_autocomplete(self : NativeAppLoop) -> Bool {
  match
    self.driver
    .host()
    .command_autocomplete(self.editor.text_before_cursor()) {
    Some((prefix, items)) => self.runtime.open_autocomplete(prefix, items)
    None => {
      self.runtime.close_autocomplete()
      false
    }
  }
}

///|
fn command_display_name(input : String) -> String {
  match slash_input_parts(input) {
    Some((id, _)) => "/" + id
    None => input
  }
}

///|
fn catalog_string(fields : Map[String, Json], key : String) -> String {
  match fields.get(key) {
    Some(Json::String(value)) => value
    _ => ""
  }
}

///|
fn model_catalog_items(value : Json) -> Array[@ui.SelectItem] {
  let items : Array[@ui.SelectItem] = []
  guard value is Json::Array(entries) else { return items }
  for entry in entries {
    guard entry is Json::Object(fields) else { continue }
    let id = catalog_string(fields, "id")
    if id.is_empty() {
      continue
    }
    let label = catalog_string(fields, "label")
    let active = fields.get("active") == Some(Json::boolean(true))
    let head = (if active { "* " } else { "  " }) +
      (if label.is_empty() { id } else { label })
    let efforts : Array[String] = []
    match fields.get("thinking_efforts") {
      Some(Json::Array(values)) =>
        for value in values {
          match value {
            Json::String(effort) => efforts.push(effort)
            _ => ()
          }
        }
      _ => ()
    }
    if efforts.is_empty() {
      items.push({
        value: "/model " + id,
        label: head,
        description: id,
      })
    } else {
      for effort in efforts {
        items.push({
          value: "/model " + id + " " + effort,
          label: head + " · effort: " + effort,
          description: id,
        })
      }
    }
  }
  items
}

///|
fn skills_catalog_items(value : Json) -> Array[@ui.SelectItem] {
  let items : Array[@ui.SelectItem] = []
  guard value is Json::Object(root) else { return items }
  guard root.get("kind") == Some(Json::string("skills_catalog")) else {
    return items
  }
  guard root.get("skills") is Some(Json::Array(entries)) else { return items }
  for entry in entries {
    guard entry is Json::Object(fields) else { continue }
    let name = catalog_string(fields, "name")
    if name.is_empty() {
      continue
    }
    let scope = catalog_string(fields, "scope")
    let description = catalog_string(fields, "description")
    items.push({
      value: "$" + name,
      label: "[" + scope + "] " + name,
      description,
    })
  }
  items
}

///|
fn session_catalog_items(value : Json) -> Array[@ui.SelectItem] {
  let items : Array[@ui.SelectItem] = []
  guard value is Json::Object(root) else { return items }
  guard root.get("kind") == Some(Json::string("session_catalog")) else {
    return items
  }
  guard root.get("sessions") is Some(Json::Array(entries)) else { return items }
  for entry in entries {
    guard entry is Json::Object(fields) else { continue }
    let id = catalog_string(fields, "id")
    if id.is_empty() {
      continue
    }
    let current = fields.get("current") == Some(Json::boolean(true))
    items.push({
      value: "/resume " + id,
      label: (if current { "* " } else { "  " }) + id,
      description: if current { "current" } else { "" },
    })
  }
  items
}

///|
fn NativeAppLoop::open_catalog_picker(
  self : NativeAppLoop,
  input : String,
  outcome : @posoco.CommandOutcome,
) -> Bool {
  let command = command_display_name(input)
  guard outcome is @posoco.CommandOutcome::Success(structured~, ..) else {
    return false
  }
  guard structured is Some(value) else { return false }
  let items = if command == "/model" {
    model_catalog_items(value)
  } else if command == "/skills" {
    skills_catalog_items(value)
  } else if command == "/sessions" {
    session_catalog_items(value)
  } else {
    []
  }
  if items.is_empty() {
    return false
  }
  self.runtime.open_autocomplete("", items)
}

///|
fn NativeAppLoop::render_command_outcome(
  self : NativeAppLoop,
  command : String,
  outcome : @posoco.CommandOutcome,
) -> Unit {
  let shell = self.driver.host().shell()
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      if !feedback.is_empty() {
        ignore(shell.append_notice(command + ": " + feedback))
      }
      match structured {
        Some(value) => ignore(shell.append_notice(value.stringify()))
        None => ()
      }
    }
    @posoco.CommandOutcome::Failure(reason~) =>
      ignore(shell.append_error(command + ": " + reason))
    @posoco.CommandOutcome::NeedsInput(prompt~) =>
      ignore(shell.append_notice(command + " needs input: " + prompt))
  }
}

///|
fn NativeAppLoop::start_skill_mention(
  self : NativeAppLoop,
  group : @async.TaskGroup[Unit],
  input : String,
) -> Unit {
  if self.driver.is_running() {
    ignore(
      self.driver
      .host()
      .shell()
      .append_error(input + " waits until the running turn ends"),
    )
    return
  }
  if self.command_task is Some(_) || self.command_lock.is_held() {
    ignore(
      self.driver
      .host()
      .shell()
      .append_error(input + " cannot run while another command is active"),
    )
    return
  }
  guard parse_skill_mention(input) is Some((name, _)) else {
    ignore(self.driver.host().shell().append_error("$ needs a skill name"))
    return
  }
  let trimmed = input.trim().to_owned()
  self.editor.record_history(trimmed)
  self.editor.clear()
  self.runtime.close_autocomplete()
  self.acquire_command("activating skill " + name)
  self.command_name = Some(trimmed)
  let host = self.driver.host()
  self.command_task = Some(
    group.spawn(
      () => host.invoke_skill_mention(name),
      allow_failure=true,
    ),
  )
}

///|
fn NativeAppLoop::start_command(
  self : NativeAppLoop,
  group : @async.TaskGroup[Unit],
  input : String,
) -> Unit {
  if self.command_task is Some(_) || self.command_lock.is_held() {
    ignore(
      self.driver
      .host()
      .shell()
      .append_error(input + " cannot run while another command is active"),
    )
    return
  }
  let trimmed = input.trim().to_owned()
  let command = match slash_input_parts(trimmed) {
    Some((id, _)) => "/" + id
    None => trimmed
  }
  self.editor.record_history(trimmed)
  self.editor.clear()
  self.runtime.close_autocomplete()
  self.acquire_command("running " + command)
  self.command_name = Some(trimmed)
  let host = self.driver.host()
  self.command_task = Some(
    group.spawn(
      () => host.invoke_slash_command(trimmed),
      allow_failure=true,
    ),
  )
}

///|
fn NativeAppLoop::poll_command_settle(
  self : NativeAppLoop,
  group : @async.TaskGroup[Unit],
) -> Bool {
  guard self.command_task is Some(task) else { return false }
  let result : Result[@posoco.CommandOutcome?, Error] = Ok(task.try_wait()) catch {
    error => Err(error)
  }
  match result {
    Ok(None) => false
    Ok(Some(outcome)) => {
      let input = match self.command_name {
        Some(value) => value
        None => "/command"
      }
      let command = command_display_name(input)
      self.command_task = None
      self.command_name = None
      if input.has_prefix("$") {
        match skill_activation_prompt(input, outcome) {
          Ok(prompt) => {
            ignore(self.release_command())
            if !self.driver.start_expanded(group, prompt, command) {
              ignore(
                self.driver
                .host()
                .shell()
                .append_error(input + " could not start while another turn is active"),
              )
            }
          }
          Err(reason) => {
            ignore(self.driver.host().shell().append_error(input + ": " + reason))
            ignore(self.release_command())
          }
        }
      } else {
        let is_catalog_command =
          input == "/model" || input == "/skills" || input == "/sessions"
        let opened_picker =
          is_catalog_command && self.open_catalog_picker(input, outcome)
        if !opened_picker {
          if is_catalog_command {
            match outcome {
              @posoco.CommandOutcome::Success(feedback~, ..) =>
                if !feedback.is_empty() {
                  ignore(self.driver.host().shell().append_notice(command + ": " + feedback))
                }
              _ => self.render_command_outcome(command, outcome)
            }
          } else {
            self.render_command_outcome(command, outcome)
          }
        }
        ignore(self.release_command())
      }
      true
    }
    Err(error) => {
      let command = match self.command_name {
        Some(value) => value
        None => "/command"
      }
      self.command_task = None
      self.command_name = None
      ignore(
        self.driver
        .host()
        .shell()
        .append_error(command + " failed: " + error.to_string()),
      )
      ignore(self.release_command())
      true
    }
  }
}

///|
fn NativeAppLoop::apply_editor_action(
  self : NativeAppLoop,
  group : @async.TaskGroup[Unit],
  action : EditorInputAction,
) -> NativeLoopSignal {
  match action {
    EditorSubmit(prompt) => {
      let trimmed = prompt.trim().to_owned()
      if trimmed == "/exit" || trimmed == "/quit" {
        return LoopExit
      } else if trimmed == "/rewind" {
        return LoopOpenRewind
      } else if trimmed == "/login" || trimmed.has_prefix("/login ") {
        if self.driver.is_running() {
          ignore(
            self.driver
            .host()
            .shell()
            .append_error("/login waits until the running turn ends"),
          )
          return LoopContinue
        }
        match setup_login_provider(trimmed) {
          Ok(provider) => {
            self.editor.record_history(trimmed)
            self.editor.clear()
            self.runtime.close_autocomplete()
            return LoopLogin(provider)
          }
          Err(reason) => {
            ignore(self.driver.host().shell().append_error(reason))
            return LoopContinue
          }
        }
      } else if trimmed.has_prefix("/") {
        self.start_command(group, trimmed)
      } else if trimmed.has_prefix("$") {
        self.start_skill_mention(group, trimmed)
      } else {
        ignore(self.driver.submit(group, prompt))
      }
      LoopContinue
    }
    EditorComplete => {
      ignore(self.refresh_autocomplete())
      LoopContinue
    }
    EditorChanged => {
      ignore(self.refresh_autocomplete())
      LoopContinue
    }
    EditorUnchanged => LoopContinue
  }
}

///|
fn NativeAppLoop::apply_shell_action(
  self : NativeAppLoop,
  action : ShellInputAction,
) -> NativeLoopSignal {
  match action {
    InputShutdown => LoopExit
    InputInterrupt => {
      ignore(self.driver.interrupt())
      LoopContinue
    }
    InputClearEditor => {
      self.editor.clear()
      LoopContinue
    }
    InputOpenRewind => LoopOpenRewind
    InputDismissOverlay => LoopDismissOverlay
    InputToggleThinking => {
      ignore(self.driver.host().shell().toggle_thinking_expanded())
      LoopToggleThinking
    }
    InputToggleToolOutput => {
      ignore(self.driver.host().shell().toggle_tool_output_expanded())
      LoopToggleToolOutput
    }
    InputConsume | InputPass => LoopContinue
  }
}

///|
/// Run one non-blocking terminal iteration.
///
/// A caller that handles rewind/autocomplete/overlay flows may consume the
/// returned signal and then resume ticking the same loop.
pub fn NativeAppLoop::tick(
  self : NativeAppLoop,
  group : @async.TaskGroup[Unit],
) -> NativeLoopSignal {
  ignore(self.driver.poll_settle(group))
  ignore(self.poll_command_settle(group))

  let signal = match self.runtime.poll_once(0UL, self.runtime_state()) {
    RuntimeIdle
    | RuntimeUiUpdated
    | RuntimeUiSettled
    | RuntimeResize(_, _)
    | RuntimeFocus(_) => LoopContinue
    RuntimeRewindAction(action) =>
      match action {
        @ui.RewindPicked(message_index) => LoopApplyRewind(message_index)
        @ui.RewindUnhandled | @ui.RewindChanged | @ui.RewindCancelled =>
          LoopContinue
      }
    RuntimeEditorKey(event) =>
      self.apply_editor_action(group, handle_editor_key(self.editor, event))
    RuntimePaste(text) =>
      self.apply_editor_action(group, handle_editor_paste(self.editor, text))
    RuntimeShellAction(action) => self.apply_shell_action(action)
    RuntimeTerminalError(status) => LoopTerminalFailed(status)
  }

  if signal is LoopTerminalFailed(_) {
    return signal
  }

  let scrollback_status = self.runtime.flush_scrollback()
  if scrollback_status != 0 {
    return LoopTerminalFailed(scrollback_status)
  }
  let render_status = self.runtime.render()
  if render_status != 0 {
    return LoopTerminalFailed(render_status)
  }

  signal
}

///|
/// Convenience driver for the plain interactive loop.
///
/// Signals that need an application command/modal owner are returned to the
/// caller rather than silently swallowed. The 8ms cooperative sleep keeps the
/// Agent/model tasks progressing while capping idle redraw latency.
pub async fn NativeAppLoop::run_until_signal(
  self : NativeAppLoop,
  group : @async.TaskGroup[Unit],
) -> NativeLoopSignal {
  while true {
    let signal = self.tick(group)
    if signal != LoopContinue {
      return signal
    }
    @async.sleep(8)
  }
  LoopExit
}

///|
/// Idempotent process shutdown ordering: cancel UI waiters/terminal first,
/// then cancel/drain any Agent turn and shut down the Agent.
pub async fn NativeAppLoop::shutdown_for_recompose(
  self : NativeAppLoop,
) -> Unit {
  self.runtime.close_ui_only()
  match self.command_task {
    Some(task) => {
      task.cancel()
      try {
        let _ = task.wait()
      } catch {
        _ => ()
      }
      self.command_task = None
      self.command_name = None
    }
    None => ()
  }
  self.driver.shutdown()
}

///|
pub async fn NativeAppLoop::shutdown(self : NativeAppLoop) -> Unit {
  self.runtime.close()
  match self.command_task {
    Some(task) => {
      task.cancel()
      try {
        let _ = task.wait()
      } catch {
        _ => ()
      }
      self.command_task = None
      self.command_name = None
    }
    None => ()
  }
  self.driver.shutdown()
}
