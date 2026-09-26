/// Terminal-loop controller for interactive UiPort requests.
///
/// NativeUiPort transports pending requests; UiRequestPanelModel owns local
/// interaction semantics. This controller joins the two while keeping one
/// focused ask active at a time.

///|
struct ActiveUiRequest {
  pending : PendingUiRequest
  panel : UiRequestPanelModel
}

///|
pub struct NativeUiController {
  ui : NativeUiPort
  mut active : ActiveUiRequest?
}

///|
pub fn NativeUiController::new(ui : NativeUiPort) -> NativeUiController {
  { ui, active: None }
}

///|
/// Pull at most one queued request into focus. False means no request is active.
pub fn NativeUiController::pump(self : NativeUiController) -> Bool {
  if self.active is Some(_) {
    return true
  }
  match self.ui.take_request() {
    None => false
    Some(pending) => {
      self.active = Some({
        pending,
        panel: UiRequestPanelModel::new(pending.request()),
      })
      true
    }
  }
}

///|
pub fn NativeUiController::is_active(self : NativeUiController) -> Bool {
  self.active is Some(_)
}

///|
pub fn NativeUiController::active_prompt(self : NativeUiController) -> String? {
  match self.active {
    Some(active) => Some(active.panel.prompt())
    None => None
  }
}

///|
pub fn NativeUiController::active_kind(
  self : NativeUiController,
) -> UiRequestPanelKind? {
  match self.active {
    Some(active) => Some(active.panel.kind())
    None => None
  }
}

///|
pub fn NativeUiController::active_input_text(
  self : NativeUiController,
) -> String? {
  match self.active {
    Some(active) =>
      if active.panel.kind() == UiPanelInput {
        Some(active.panel.input_text())
      } else {
        None
      }
    None => None
  }
}

///|
pub fn NativeUiController::active_selected_index(
  self : NativeUiController,
) -> Int? {
  match self.active {
    Some(active) =>
      if active.panel.kind() == UiPanelInput {
        None
      } else {
        Some(active.panel.selected_index())
      }
    None => None
  }
}

///|
/// Feed a terminal key into the focused request.
///
/// True means the request settled and its waiter was released.
pub fn NativeUiController::handle_key(
  self : NativeUiController,
  event : @ui.TerminalEvent,
) -> Bool {
  guard self.active is Some(active) else {
    return false
  }
  match active.panel.handle_key(event) {
    None => false
    Some(response) => {
      let delivered = active.pending.respond(response)
      self.active = None
      delivered
    }
  }
}

///|
pub fn NativeUiController::handle_paste(
  self : NativeUiController,
  text : String,
) -> Unit {
  match self.active {
    Some(active) => active.panel.handle_paste(text)
    None => ()
  }
}
