/// First-run native setup shell.
///
/// This loop deliberately has no Agent. It keeps the Ratatui terminal alive
/// while provider composition is unavailable and exposes only the recovery
/// actions that are meaningful before a model exists. The actual credential
/// and OAuth flow is executed by the host after suspending the terminal.

///|
pub(all) enum NativeSetupSignal {
  SetupContinue
  SetupLogin(String)
  SetupRetry
  SetupExit
  SetupTerminalFailed(Int)
} derive(Eq)

///|
pub extend NativeSetupSignal with Eq::{equal, not_equal}

///|
pub struct NativeSetupLoop {
  shell : NativeShell
  ui : NativeUiPort
  runtime : NativeRuntime
  editor : @ui.EditorModel
  mut command_busy : Bool
}

///|
pub fn NativeSetupLoop::new(
  terminal : @ui.Terminal,
  reason : String,
) -> NativeSetupLoop {
  let shell = NativeShell::new()
  ignore(shell.append_notice("⚠ setup required"))
  if !reason.trim().is_empty() {
    ignore(shell.append_error(reason.trim().to_owned()))
  }
  ignore(
    shell.append_notice(
      "Use /login [provider] to authenticate, /retry after external config changes, or /exit.",
    ),
  )
  let ui = NativeUiPort::new()
  let editor = @ui.EditorModel::new()
  let router = NativeInputRouter::new(NativeUiController::new(ui))
  let rewind = @ui.RewindPickerModel::new()
  let runtime = NativeRuntime::new(terminal, shell, router, editor, rewind)
  { shell, ui, runtime, editor, command_busy: false, }
}

///|
pub fn NativeSetupLoop::append_notice(
  self : NativeSetupLoop,
  message : String,
) -> Int {
  self.shell.append_notice(message)
}

///|
pub fn NativeSetupLoop::append_error(
  self : NativeSetupLoop,
  message : String,
) -> Int {
  self.shell.append_error(message)
}

///|
pub fn NativeSetupLoop::auth_ui(self : NativeSetupLoop) -> NativeAuthUi {
  NativeAuthUi::new(self.ui)
}

///|
pub fn NativeSetupLoop::set_command_busy(
  self : NativeSetupLoop,
  value : Bool,
) -> Unit {
  self.command_busy = value
  self.editor.set_submit_disabled(value)
}

///|
fn setup_completion_items(prefix : String) -> Array[@ui.SelectItem] {
  let commands : Array[(String, String)] = [
    ("/login", "Authenticate a provider"),
    ("/retry", "Retry Cetas composition"),
    ("/exit", "Quit Cetas"),
  ]
  let items : Array[@ui.SelectItem] = []
  for entry in commands {
    if entry.0.has_prefix(prefix) {
      items.push({ value: entry.0, label: entry.0, description: entry.1, })
    }
  }
  items
}

///|
fn NativeSetupLoop::refresh_autocomplete(self : NativeSetupLoop) -> Bool {
  let text = self.editor.text_before_cursor()
  if !text.has_prefix("/") || text.contains(" ") {
    self.runtime.close_autocomplete()
    return false
  }
  let items = setup_completion_items(text)
  if items.is_empty() {
    self.runtime.close_autocomplete()
    false
  } else {
    self.runtime.open_autocomplete(text, items)
  }
}

///|
fn setup_login_provider(input : String) -> Result[String, String] {
  let trimmed = input.trim().to_owned()
  if trimmed == "/login" {
    return Ok("")
  }
  if !trimmed.has_prefix("/login ") {
    return Err("not a login command")
  }
  let tail = trimmed[7:].trim().to_owned()
  if tail.is_empty() {
    return Ok("")
  }
  if tail.contains(" ") || tail.contains("\t") {
    return Err(
      "bootstrap /login accepts one provider; authentication method is selected securely in the login flow",
    )
  }
  Ok(tail)
}

///|
fn NativeSetupLoop::submit(
  self : NativeSetupLoop,
  input : String,
) -> NativeSetupSignal {
  let trimmed = input.trim().to_owned()
  if trimmed.is_empty() {
    return SetupContinue
  }
  self.editor.record_history(trimmed)
  self.editor.clear()
  self.runtime.close_autocomplete()
  if trimmed == "/exit" || trimmed == "/quit" {
    return SetupExit
  }
  if trimmed == "/retry" {
    return SetupRetry
  }
  if trimmed == "/login" || trimmed.has_prefix("/login ") {
    match setup_login_provider(trimmed) {
      Ok(provider) => return SetupLogin(provider)
      Err(reason) => {
        ignore(self.shell.append_error(reason))
        return SetupContinue
      }
    }
  }
  ignore(
    self.shell.append_error(
      "No model provider is configured. Use /login [provider] before sending a query.",
    ),
  )
  SetupContinue
}

///|
fn NativeSetupLoop::editor_action(
  self : NativeSetupLoop,
  action : EditorInputAction,
) -> NativeSetupSignal {
  match action {
    EditorSubmit(text) => self.submit(text)
    EditorComplete | EditorChanged => {
      ignore(self.refresh_autocomplete())
      SetupContinue
    }
    EditorUnchanged => SetupContinue
  }
}

///|
pub fn NativeSetupLoop::tick(self : NativeSetupLoop) -> NativeSetupSignal {
  let state : RuntimeInputState = {
    now_ms: @async.now().reinterpret_as_uint64(),
    editor_has_text: !self.editor.text().is_empty(),
    in_turn: false,
    compact_pending: false,
    command_busy: self.command_busy,
    dismissible_overlay_visible: false,
  }
  let signal = match self.runtime.poll_once(0UL, state) {
    RuntimeIdle
    | RuntimeUiUpdated
    | RuntimeUiSettled
    | RuntimeResize(_, _)
    | RuntimeFocus(_) => SetupContinue
    RuntimeEditorKey(event) =>
      self.editor_action(handle_editor_key(self.editor, event))
    RuntimePaste(text) =>
      self.editor_action(handle_editor_paste(self.editor, text))
    RuntimeShellAction(InputShutdown) => SetupExit
    RuntimeShellAction(InputClearEditor) => {
      self.editor.clear()
      SetupContinue
    }
    RuntimeShellAction(_) => SetupContinue
    RuntimeRewindAction(_) => SetupContinue
    RuntimeTerminalError(status) => SetupTerminalFailed(status)
  }
  if signal is SetupTerminalFailed(_) {
    return signal
  }
  let scrollback = self.runtime.flush_scrollback()
  if scrollback != 0 {
    return SetupTerminalFailed(scrollback)
  }
  let rendered = self.runtime.render()
  if rendered != 0 {
    return SetupTerminalFailed(rendered)
  }
  signal
}

///|
pub async fn NativeSetupLoop::run_until_signal(
  self : NativeSetupLoop,
) -> NativeSetupSignal {
  while true {
    let signal = self.tick()
    if signal != SetupContinue {
      return signal
    }
    @async.sleep(8)
  }
  SetupExit
}

///|
test "setup shell parses recovery commands without an Agent" {
  assert_eq(setup_login_provider("/login"), Ok(""))
  assert_eq(setup_login_provider("/login openai"), Ok("openai"))
  assert_true(setup_login_provider("/login openai oauth") is Err(_))
  let items = setup_completion_items("/l")
  assert_eq(items.length(), 1)
  assert_eq(items[0].value, "/login")
}
