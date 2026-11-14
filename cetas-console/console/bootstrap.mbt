///|
/// Provider setup before an Agent exists. A fresh CETAS_HOME cannot compose
/// ConsoleRuntime until at least one provider yields a model catalog. Keep
/// first-run authentication on the same provider-owned Posoco seam as /login.
pub struct ConsoleBootstrap {
  fs : &@workspace.WorkspaceFs
  home : String
  hub : EventHub
  ui_registry : UiRegistry
  /// Same explicit native terminal UI projection opt-in as a composed
  /// runtime; first-run authentication renders through it.
  native_ui : Bool
}

///|
pub fn console_bootstrap(
  fs : &@workspace.WorkspaceFs,
  home : String,
  sink : (String) -> Unit,
  native_ui~ : Bool = false,
) -> ConsoleBootstrap {
  let hub = EventHub::new()
  if native_ui {
    hub.enable_native_retention()
  }
  hub.attach(sink)
  { fs, home, hub, ui_registry: UiRegistry::new(), native_ui, }
}

///|
/// The unauthenticated inventory does not need a model, network request, or
/// ConsoleRuntime. This is the only command permitted before composition.
pub async fn ConsoleBootstrap::providers_json(self : ConsoleBootstrap) -> Json {
  let settings = @cetas_core.load_provider_settings(
    self.fs,
    home=self.home,
    label="cetas-go.bootstrap",
  ) catch {
    _ => return Json::object({ "providers": Json::array([]) })
  }
  let providers : Array[Json] = []
  for row in provider_inventory(settings) {
    let (id, methods) = row
    let method_json : Array[Json] = []
    for auth_method in methods {
      method_json.push(Json::string(auth_method))
    }
    providers.push(
      Json::object({
        "id": Json::string(id),
        "name": Json::string(id),
        "signed_in": Json::boolean(false),
        "methods": Json::array(method_json),
      }),
    )
  }
  Json::object({ "providers": Json::array(providers) })
}

///|
/// Preserve the same secret masking, cancellation, and tagged credential
/// storage as ConsoleRuntime::login; never copy key material into a frame.
pub async fn ConsoleBootstrap::login(
  self : ConsoleBootstrap,
  provider : String,
  auth_method : String,
) -> String {
  if !provider_id_is_valid(provider) {
    return login_failure_json(provider, auth_method, "invalid provider id")
  }
  let settings = @cetas_core.load_provider_settings(
    self.fs,
    home=self.home,
    label="cetas-go.bootstrap",
  ) catch {
    _ =>
      return login_failure_json(
        provider, auth_method, "cannot read provider settings",
      )
  }
  let selected = @cetas_core.resolve_login_method(
    provider,
    auth_method,
    settings~,
  ) catch {
    _ =>
      return login_failure_json(
        provider, auth_method, "unknown provider or auth_method",
      )
  }
  let auth = HubAuthUi::HubAuthUi(
    HubUiPort::new_secret(
      self.hub,
      self.ui_registry,
      "",
      native_ui=self.native_ui,
    ),
  )
  let outcome = @cetas_core.login_provider(
    provider,
    selected,
    settings~,
    device_id="",
    auth as &@oauth.AuthInteraction,
    auth as &@oauth.AuthPromptInteraction,
  ) catch {
    _ =>
      return login_failure_json(
        provider, selected, "authentication failed or was cancelled",
      )
  }
  // A cancelled login must never persist a late provider response.
  if @async.is_being_cancelled() {
    return login_failure_json(provider, selected, "authentication cancelled")
  }
  credential_store(self.fs, self.home).write(
    outcome.provider_id,
    outcome.credential,
  ) catch {
    _ =>
      return login_failure_json(
        provider, selected, "credential could not be saved",
      )
  }
  @cetas_core.login_outcome_json(outcome)
}

///|
pub fn ConsoleBootstrap::resolve_ui(
  self : ConsoleBootstrap,
  id : String,
  response : String,
) -> Unit {
  self.ui_registry.resolve(id, response)
}

///|
pub fn ConsoleBootstrap::cancel_all(self : ConsoleBootstrap) -> Unit {
  self.ui_registry.cancel_all()
}

///|
pub fn ConsoleBootstrap::emit_event(
  self : ConsoleBootstrap,
  event_type : String,
  extra~ : Array[(String, Json)] = [],
) -> Unit {
  self.hub.emit("", "", event_type, extra~)
}
