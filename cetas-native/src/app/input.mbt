/// Global terminal-shell input reducer.
///
/// Crossterm already normalizes terminal escape encodings. This layer owns the
/// shell-level gesture semantics that cetas-js previously implemented around
/// pi-tui: key-release suppression, ctrl+c, modal precedence, ESC interrupt,
/// idle double-ESC rewind, and the global collapse toggles.
///
/// The reducer has no clock or side effects. Callers pass `now_ms` and apply
/// the returned action at the application boundary.

///|
pub(all) enum ShellInputAction {
  InputPass
  InputConsume
  InputShutdown
  InputDismissOverlay
  InputInterrupt
  InputClearEditor
  InputOpenRewind
  InputToggleThinking
  InputToggleToolOutput
} derive(Eq)

///|
pub extend ShellInputAction with Eq::{equal, not_equal}

///|
pub struct ShellInputModel {
  mut last_escape_at_ms : UInt64?
}

///|
pub fn ShellInputModel::new() -> ShellInputModel {
  { last_escape_at_ms: None }
}

///|
pub fn ShellInputModel::last_escape_at_ms(self : ShellInputModel) -> UInt64? {
  self.last_escape_at_ms
}

///|
/// Exact cetas-js rewind gesture contract: the second idle ESC must arrive at
/// or after the first and strictly before the 500ms deadline.
pub fn should_open_rewind_on_escape(
  last_escape_at_ms : UInt64?,
  now_ms : UInt64,
  window_ms~ : UInt64 = 500UL,
) -> Bool {
  guard last_escape_at_ms is Some(previous) else {
    return false
  }
  now_ms >= previous && now_ms - previous < window_ms
}

///|
/// Reduce one normalized terminal event into a shell-level action.
///
/// Ordering mirrors cetas-js TerminalShell.handleInput:
/// 1. release events are consumed;
/// 2. ctrl+c wins globally;
/// 3. focused modal/ask UI receives its own input;
/// 4. a generic dismissible overlay closes before shell gestures;
/// 5. ESC interrupts an active turn/compact operation;
/// 6. idle ESC clears/arms or opens rewind on a second press;
/// 7. ctrl+t / ctrl+o are global collapse toggles;
/// 8. command-busy swallows everything else.
pub fn ShellInputModel::handle_global_key(
  self : ShellInputModel,
  event : @ui.TerminalEvent,
  now_ms : UInt64,
  editor_has_text : Bool,
  in_turn : Bool,
  compact_pending : Bool,
  command_busy : Bool,
  focused_ui_active : Bool,
  dismissible_overlay_visible : Bool,
) -> ShellInputAction {
  if event.is_key_release() {
    return InputConsume
  }

  if event.matches_char(99U, @ui.modifier_control()) {
    return InputShutdown
  }

  if focused_ui_active {
    return InputPass
  }

  if dismissible_overlay_visible {
    return InputDismissOverlay
  }

  if event.matches_key(@ui.KeyEscape, 0U) && (in_turn || compact_pending) {
    return InputInterrupt
  }

  if !in_turn &&
    !command_busy &&
    event.matches_key(@ui.KeyEscape, 0U) {
    if editor_has_text {
      self.last_escape_at_ms = Some(now_ms)
      return InputClearEditor
    }

    if should_open_rewind_on_escape(self.last_escape_at_ms, now_ms) {
      self.last_escape_at_ms = None
      return InputOpenRewind
    }

    self.last_escape_at_ms = Some(now_ms)
    return InputConsume
  }

  if event.matches_char(116U, @ui.modifier_control()) {
    return InputToggleThinking
  }

  if event.matches_char(111U, @ui.modifier_control()) {
    return InputToggleToolOutput
  }

  if command_busy {
    return InputConsume
  }

  InputPass
}

///|
fn validation_key(
  code : UInt,
  codepoint : UInt,
  modifiers : UInt,
  action : UInt,
) -> @ui.TerminalEvent {
  @ui.TerminalEvent::{
    abi_version: 2U,
    struct_size: 56U,
    kind: 1U,
    key_code: code,
    codepoint,
    modifiers,
    key_action: action,
    width: 0U,
    height: 0U,
    mouse_x: 0U,
    mouse_y: 0U,
    mouse_kind: 0U,
    mouse_button: 0U,
    text_len: 0U,
  }
}

///|
pub fn input_validation_marker() -> Int {
  let input = ShellInputModel::new()
  let escape = validation_key(3U, 0U, 0U, 1U)
  let escape_release = validation_key(3U, 0U, 0U, 3U)
  let ctrl_c = validation_key(1U, 99U, @ui.modifier_control(), 1U)
  let ctrl_t = validation_key(1U, 116U, @ui.modifier_control(), 1U)
  let ctrl_o = validation_key(1U, 111U, @ui.modifier_control(), 1U)

  if input.handle_global_key(
    escape_release,
    1000UL,
    false,
    false,
    false,
    false,
    false,
    false,
  ) != InputConsume {
    return 0
  }

  if input.handle_global_key(
    ctrl_c,
    1000UL,
    false,
    false,
    false,
    false,
    true,
    false,
  ) != InputShutdown {
    return 0
  }

  // Focused asks/modals own their input and must not arm double-ESC.
  if input.handle_global_key(
    escape,
    1000UL,
    false,
    false,
    false,
    false,
    true,
    false,
  ) != InputPass ||
    input.last_escape_at_ms() is Some(_) {
    return 0
  }

  if input.handle_global_key(
    escape,
    1000UL,
    false,
    true,
    false,
    false,
    false,
    false,
  ) != InputInterrupt {
    return 0
  }

  if input.handle_global_key(
    escape,
    1000UL,
    true,
    false,
    false,
    false,
    false,
    false,
  ) != InputClearEditor ||
    input.last_escape_at_ms() != Some(1000UL) {
    return 0
  }

  if input.handle_global_key(
    escape,
    1499UL,
    false,
    false,
    false,
    false,
    false,
    false,
  ) != InputOpenRewind ||
    input.last_escape_at_ms() is Some(_) {
    return 0
  }

  // Exactly 500ms is outside the window and re-arms the gesture.
  if input.handle_global_key(
    escape,
    2000UL,
    false,
    false,
    false,
    false,
    false,
    false,
  ) != InputConsume ||
    input.handle_global_key(
      escape,
      2500UL,
      false,
      false,
      false,
      false,
      false,
      false,
    ) != InputConsume ||
    input.last_escape_at_ms() != Some(2500UL) {
    return 0
  }

  // A backwards timestamp cannot satisfy the gesture.
  if input.handle_global_key(
    escape,
    2400UL,
    false,
    false,
    false,
    false,
    false,
    false,
  ) != InputConsume ||
    input.last_escape_at_ms() != Some(2400UL) {
    return 0
  }

  if input.handle_global_key(
    escape,
    2401UL,
    false,
    false,
    false,
    false,
    false,
    true,
  ) != InputDismissOverlay {
    return 0
  }

  if input.handle_global_key(
    ctrl_t,
    3000UL,
    false,
    false,
    false,
    false,
    false,
    false,
  ) != InputToggleThinking ||
    input.handle_global_key(
      ctrl_o,
      3000UL,
      false,
      false,
      false,
      false,
      false,
      false,
    ) != InputToggleToolOutput {
    return 0
  }

  // Command-busy consumes ordinary keys, but focused UI above it still wins.
  let plain_q = validation_key(1U, 113U, 0U, 1U)
  if input.handle_global_key(
    plain_q,
    3000UL,
    false,
    false,
    false,
    true,
    false,
    false,
  ) != InputConsume ||
    input.handle_global_key(
      plain_q,
      3000UL,
      false,
      false,
      false,
      true,
      true,
      false,
    ) != InputPass {
    return 0
  }

  1
}
