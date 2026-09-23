///|
/// Manifest-only extension that contributes a host-constructed UiPort to the
/// composition. Hosts keep owning their transport-specific UI (a tty port, a
/// JS bridge); contributing it as an extension routes every request through
/// posoco's aggregated UiPort, so extensions that resolve `Capability::Ui`
/// from their CompositionView capture the composed port instead of holding a
/// bypassing raw reference.
pub struct UiPortExtension {
  ui : &@posoco.UiPort
  id : String
}

///|
pub fn UiPortExtension::UiPortExtension(
  id~ : String,
  ui~ : &@posoco.UiPort,
) -> UiPortExtension {
  { ui, id, }
}

///|
pub impl @posoco.Extension for UiPortExtension with fn extension_id(
  self : UiPortExtension,
) -> String {
  self.id
}

///|
pub impl @posoco.Extension for UiPortExtension with fn manifest(
  self : UiPortExtension,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id=self.id,
    models=[],
    decisions=[],
    tools=[],
    sessions=[],
    observers=[],
    hooks=[],
    memory=[],
    lifecycle=[],
    commands=[],
    ui=[self.ui],
    prompt_contributors=[],
    requires=[],
  )
}

///|
pub extend UiPortExtension with @posoco.Extension::{extension_id, manifest}
