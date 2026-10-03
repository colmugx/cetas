/// Application-level input routing.
///
/// This is the single precedence boundary between focused interactive UI and
/// shell-global gestures. A mounted UiRequest owns its keys first; otherwise
/// input falls through to ShellInputModel. The router performs no Agent or
/// terminal side effects.

///|
pub(all) enum NativeInputRoute {
  RouteUiActive
  RouteUiSettled
  RouteShell(ShellInputAction)
} derive(Eq)

///|
pub extend NativeInputRoute with Eq::{equal, not_equal}

///|
pub struct NativeInputRouter {
  shell : ShellInputModel
  ui : NativeUiController
}

///|
pub fn NativeInputRouter::new(ui : NativeUiController) -> NativeInputRouter {
  { shell: ShellInputModel::new(), ui, }
}

///|
/// Pull a newly queued UiRequest into focus if there is no active one.
pub fn NativeInputRouter::pump_ui(self : NativeInputRouter) -> Bool {
  self.ui.pump()
}

///|
pub fn NativeInputRouter::ui_active(self : NativeInputRouter) -> Bool {
  self.ui.is_active()
}

///|
pub fn NativeInputRouter::ui_prompt(self : NativeInputRouter) -> String? {
  self.ui.active_prompt()
}

///|
pub fn NativeInputRouter::ui_kind(
  self : NativeInputRouter,
) -> UiRequestPanelKind? {
  self.ui.active_kind()
}

///|
pub fn NativeInputRouter::ui_input_text(self : NativeInputRouter) -> String? {
  self.ui.active_input_text()
}

///|
pub fn NativeInputRouter::ui_selected_index(self : NativeInputRouter) -> Int? {
  self.ui.active_selected_index()
}

///|
pub fn NativeInputRouter::ui_option_count(self : NativeInputRouter) -> Int {
  self.ui.active_option_count()
}

///|
pub fn NativeInputRouter::ui_option_label(
  self : NativeInputRouter,
  index : Int,
) -> String? {
  self.ui.active_option_label(index)
}

///|
pub fn NativeInputRouter::close_ui(self : NativeInputRouter) -> Unit {
  self.ui.close()
}

///|
/// Route one key with focused-request precedence.
///
/// ctrl+c remains a shell-global shutdown chord, matching cetas-js. Every
/// other key is owned by the focused UiRequest before overlay/ESC shortcuts.
pub fn NativeInputRouter::route_key(
  self : NativeInputRouter,
  event : @ui.TerminalEvent,
  now_ms : UInt64,
  editor_has_text : Bool,
  in_turn : Bool,
  compact_pending : Bool,
  command_busy : Bool,
  dismissible_overlay_visible : Bool,
) -> NativeInputRoute {
  if event.matches_char(99U, @ui.modifier_control()) {
    return RouteShell(InputShutdown)
  }

  if self.ui.is_active() {
    if self.ui.handle_key(event) {
      RouteUiSettled
    } else {
      RouteUiActive
    }
  } else {
    RouteShell(
      self.shell.handle_global_key(
        event, now_ms, editor_has_text, in_turn, compact_pending, command_busy, false,
        dismissible_overlay_visible,
      ),
    )
  }
}

///|
/// Paste belongs to a focused input request. False means callers should pass
/// the payload on to the main editor instead.
pub fn NativeInputRouter::route_paste(
  self : NativeInputRouter,
  text : String,
) -> Bool {
  if !self.ui.is_active() {
    return false
  }
  self.ui.handle_paste(text)
  true
}
