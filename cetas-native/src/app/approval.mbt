/// Native permission approval adapter.
///
/// The decision vocabulary intentionally matches cetas-js. The source is
/// wired to the *composed* UiPort by NativeUiBridge so Posoco's request
/// lifecycle projection remains observable.

///|
const NATIVE_APPROVAL_ONCE = "Allow once"

///|
const NATIVE_APPROVAL_SESSION = "Allow for this session"

///|
const NATIVE_APPROVAL_DENY = "Deny"

///|
pub struct NativeApprovalSource {
  mut ui : &@posoco.UiPort?
}

///|
pub fn NativeApprovalSource::new() -> NativeApprovalSource {
  { ui: None, }
}

///|
pub impl @permission.ApprovalSource for NativeApprovalSource with fn ask(
  self : NativeApprovalSource,
  request : @permission.ApprovalRequest,
) -> @permission.ApprovalDecision {
  let ui = match self.ui {
    Some(value) => value
    None =>
      return @permission.ApprovalDecision::Deny(
        reason="denied: native approval UI not composed yet",
      )
  }
  let prompt = "Allow tool '" +
    request.tool_name +
    "' (" +
    request.category +
    ")?\n" +
    request.arguments_preview
  let response = ui.request(@posoco.UiRequest::Select(
    prompt~,
    options=[
      NATIVE_APPROVAL_ONCE,
      NATIVE_APPROVAL_SESSION,
      NATIVE_APPROVAL_DENY,
    ],
    default=Some(0),
  )) catch {
    error =>
      return @permission.ApprovalDecision::Deny(
        reason="approval UI failed: " + error.to_string(),
      )
  }
  match response {
    @posoco.UiResponse::Selected(0) => @permission.ApprovalDecision::AllowOnce
    @posoco.UiResponse::Selected(1) =>
      @permission.ApprovalDecision::AllowSession
    @posoco.UiResponse::Selected(2) =>
      @permission.ApprovalDecision::Deny(reason="user declined")
    @posoco.UiResponse::Cancelled =>
      @permission.ApprovalDecision::Deny(reason="user cancelled")
    _ =>
      @permission.ApprovalDecision::Deny(
        reason="unexpected ui response to select",
      )
  }
}

///|
pub struct NativeUiBridge {
  approval : NativeApprovalSource
}

///|
pub fn NativeUiBridge::new(
  approval : NativeApprovalSource,
) -> NativeUiBridge {
  { approval, }
}

///|
pub impl @posoco.Extension for NativeUiBridge with fn extension_id(
  _self : NativeUiBridge,
) -> String {
  "cetas_native_ui_bridge"
}

///|
pub impl @posoco.Extension for NativeUiBridge with fn manifest(
  self : NativeUiBridge,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="cetas_native_ui_bridge",
    lifecycle=[self],
    requires=[@posoco.Capability::Ui],
  )
}

///|
pub impl @posoco.Lifecycle for NativeUiBridge with fn on_compose(
  self : NativeUiBridge,
  view : @posoco.CompositionView,
) -> Unit raise @posoco.CompositionError {
  self.approval.ui = view.ui()
}

///|
pub impl @posoco.Lifecycle for NativeUiBridge with fn on_shutdown(
  _self : NativeUiBridge,
) -> Unit {
  ()
}

///|
pub extend NativeApprovalSource with @permission.ApprovalSource::{ask}

///|
pub extend NativeUiBridge with @posoco.Extension::{extension_id, manifest}

///|
pub extend NativeUiBridge with @posoco.Lifecycle::{on_compose, on_shutdown, on_start}
