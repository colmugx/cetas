///|
/// Wires the approval/plan sources to the composed UiPort at composition
/// time. Declares `requires: [Capability::Ui]`, so its CompositionView
/// carries the aggregated port — the JsUiPort contributor wrapped by core's
/// request-event seam. Without this bridge the approval sources would hold a
/// raw JsUiPort reference and bypass the aggregated port (and its
/// UserRequestStarted/Finished events).
pub(all) struct UiBridge {
  blocking : BlockingApprovalSource?
  plan : PlanApprovalSource?
}

///|
pub impl @posoco.Extension for UiBridge with fn extension_id(_self : UiBridge) -> String {
  "cetas_ui_bridge"
}

///|
pub impl @posoco.Extension for UiBridge with fn manifest(self : UiBridge) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="cetas_ui_bridge",
    models=[],
    decisions=[],
    tools=[],
    sessions=[],
    observers=[],
    hooks=[],
    memory=[],
    lifecycle=[self],
    commands=[],
    ui=[],
    prompt_contributors=[],
    requires=[@posoco.Capability::Ui],
  )
}

///|
pub impl @posoco.Lifecycle for UiBridge with fn on_compose(
  self : UiBridge,
  view : @posoco.CompositionView,
) -> Unit raise @posoco.CompositionError {
  match self.blocking {
    Some(source) => source.ui = view.ui()
    None => ()
  }
  match self.plan {
    Some(source) => source.ui = view.ui()
    None => ()
  }
}

///|
pub impl @posoco.Lifecycle for UiBridge with fn on_shutdown(_self : UiBridge) -> Unit {
  ()
}

///|
pub extend UiBridge with @posoco.Extension::{extension_id, manifest}

///|
pub extend UiBridge with @posoco.Lifecycle::{on_compose, on_shutdown, on_start}
