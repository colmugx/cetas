///|
/// auth.mbt — provider sign-in and sign-out for GUI hosts.
///
/// Cetas-core owns provider discovery, the provider-owned OAuth / API-key
/// flows, credential persistence and the outcome JSON
/// (`@cetas_core.login_provider`, `login_outcome_json`). This file is the
/// console's half of that seam, and it is deliberately terminal-free: OAuth
/// notices leave as `ui.render` frames carrying the authorize URL or device
/// code, API-key prompts leave as `ui.request` frames the host answers with
/// `ui_response`, and whoever can open a browser does so itself — publishing
/// the URL is the whole contract.

///|
/// The console's credential store: one tagged record per provider below the
/// Cetas home directory (`~/.cetas/credentials`), persisted through the host's
/// `WorkspaceFs`. Credentials live under HOME, never the project working tree,
/// so they cannot be committed to a repository.
fn credential_store(
  fs : &@workspace.WorkspaceFs,
  home : String,
) -> @credentials.FileProviderCredentialStore {
  @credentials.FileProviderCredentialStore(
    fs,
    @cetas_core.credentials_path(home),
  )
}

///|
/// A host-supplied provider id becomes a credential filename, so it is checked
/// against cetas-core's `valid_provider_id` (`[A-Za-z0-9_-]`, nonempty) before
/// it reaches a path: separators and dots would otherwise address a file
/// outside `<credentials>` on login and, worse, on logout's delete. Composition
/// rejects the same ids, so no runnable provider is lost to this check.
fn provider_id_is_valid(provider : String) -> Bool {
  @cetas_core.valid_provider_id(provider)
}

///|
/// Failure counterpart of `@cetas_core.login_outcome_json`. It keeps the same
/// envelope (`type`, `structured.provider`, `structured.method`) so a host
/// renders success and failure through one code path, with `error` in place of
/// `feedback`.
fn login_failure_json(
  provider : String,
  auth_method : String,
  message : String,
) -> String {
  Json::object(
    Map::from_array([
      ("type", Json::string("error")),
      ("error", Json::string(message)),
      (
        "structured",
        Json::object(
          Map::from_array([
            ("provider", Json::string(provider)),
            ("method", Json::string(auth_method)),
          ]),
        ),
      ),
    ]),
  ).stringify()
}

///|
/// Sign-out reply. `removed` tells the host whether a stored record was
/// actually deleted, so a client can distinguish "signed out" from "was not
/// signed in"; both are successes.
fn logout_outcome_json(provider : String, removed : Bool) -> String {
  let feedback = if removed {
    "Logged out of " + provider
  } else {
    "No stored credential for " + provider
  }
  Json::object(
    Map::from_array([
      ("type", Json::string("success")),
      ("feedback", Json::string(feedback)),
      (
        "structured",
        Json::object(
          Map::from_array([
            ("provider", Json::string(provider)),
            ("removed", Json::boolean(removed)),
          ]),
        ),
      ),
    ]),
  ).stringify()
}

///|
/// Failure counterpart of `logout_outcome_json`.
fn logout_failure_json(provider : String, message : String) -> String {
  Json::object(
    Map::from_array([
      ("type", Json::string("error")),
      ("error", Json::string(message)),
      (
        "structured",
        Json::object(
          Map::from_array([
            ("provider", Json::string(provider)),
            ("removed", Json::boolean(false)),
          ]),
        ),
      ),
    ]),
  ).stringify()
}

///|
/// Provider-auth presentation over the console's UI port. Structurally the
/// same adapter as cetas-native's `NativeAuthUi`, so both hosts emit the same
/// shapes: notices are `Notice` renders (authorize URL, device code), progress
/// is a `Status` render, and prompts are blocking `ui.request`s resolved by
/// `ui_response`.
///
/// Cancellation is whatever cancels the flow: the host answers a pending
/// prompt with `{"cancelled": true}`, which surfaces here as
/// `OAuthError::Cancelled`, and coroutine cancellation is honoured between
/// OAuth poll iterations.
priv struct HubAuthUi {
  ui : HubUiPort
}

///|
fn HubAuthUi::HubAuthUi(ui : HubUiPort) -> HubAuthUi {
  { ui, }
}

///|
fn HubAuthUi::port(self : HubAuthUi) -> &@posoco.UiPort {
  self.ui
}

///|
fn HubAuthUi::notice(
  self : HubAuthUi,
  key : String,
  title : String,
  lines : Array[String],
) -> Unit {
  self
  .port()
  .render(@posoco.UiRender::{
    slot: @posoco.UiSlot::Notice,
    key,
    title: Some(title),
    body: @posoco.UiBody::Lines(lines),
    ttl_ms: None,
  })
}

///|
impl @oauth.AuthInteraction for HubAuthUi with fn notify(
  self : HubAuthUi,
  message : @oauth.AuthMessage,
) -> Unit {
  match message {
    @oauth.AuthMessage::AuthUrl(url) =>
      self.notice("oauth", "OAuth", ["Open this URL to authenticate:", url])
    @oauth.AuthMessage::DeviceCode(uri, code) =>
      self.notice("oauth", "OAuth device login", ["Open:", uri, "Code: " + code])
    @oauth.AuthMessage::Progress(message) =>
      self
      .port()
      .render(@posoco.UiRender::{
        slot: @posoco.UiSlot::Status,
        key: "oauth",
        title: None,
        body: @posoco.UiBody::Text(message),
        ttl_ms: None,
      })
  }
}

///|
impl @oauth.AuthInteraction for HubAuthUi with fn is_cancelled(
  _self : HubAuthUi,
) -> Bool {
  // Nothing host-side sets a cancelled flag: an abandoned flow is cancelled by
  // the coroutine being cancelled, or by answering its pending prompt with
  // `{"cancelled": true}`.
  @async.is_being_cancelled()
}

///|
impl @oauth.AuthPromptInteraction for HubAuthUi with fn prompt(
  self : HubAuthUi,
  request : @oauth.AuthPromptRequest,
) -> String raise @oauth.OAuthError {
  if @async.is_being_cancelled() {
    raise @oauth.OAuthError::Cancelled
  }
  match request {
    @oauth.AuthPromptRequest::Secret(message~) => {
      let response = self
        .port()
        .request(@posoco.UiRequest::Input(prompt=message, default=None)) catch {
          _ => raise @oauth.OAuthError::Cancelled
        }
      match response {
        @posoco.UiResponse::Text(value) => value
        _ => raise @oauth.OAuthError::Cancelled
      }
    }
    @oauth.AuthPromptRequest::Select(message~, options~) => {
      if options.is_empty() {
        raise @oauth.OAuthError::ParseError(
          "authentication selection has no options",
        )
      }
      let labels : Array[String] = []
      for option in options {
        let suffix = match option.description {
          Some(description) if !description.is_empty() => " — " + description
          _ => ""
        }
        labels.push(option.label + suffix)
      }
      let response = self
        .port()
        .request(
          @posoco.UiRequest::Select(
            prompt=message,
            options=labels,
            default=Some(0),
          ),
        ) catch {
          _ => raise @oauth.OAuthError::Cancelled
        }
      match response {
        @posoco.UiResponse::Selected(index) if index >= 0 &&
          index < options.length() => options[index].id
        _ => raise @oauth.OAuthError::Cancelled
      }
    }
  }
}

///|
/// Install the freshly authenticated provider's catalog into every live
/// router.
///
/// A console workspace composes its catalogs once, from settings plus
/// credentials, so a credential saved by `login` would otherwise stay
/// invisible until the next composition. This is the console's equivalent of
/// cetas-js evicting its per-provider catalog cache: rebuild that one
/// provider's static catalog from the credential that was just written and
/// hand its slots to `replace_provider_slots`, which keeps every other
/// provider's order and the active selection intact.
///
/// No network request is issued here — live discovery stays an explicit host
/// action — and every failure is swallowed: the credential is already durable,
/// so the worst case is the next composition doing this work instead.
async fn ConsoleRuntime::install_provider_catalog(
  self : ConsoleRuntime,
  provider_id : String,
  settings : Map[String, Json],
) -> Unit {
  let store = credential_store(self.fs, self.home)
  let ctx = @devkit.ExtContext::default()
  let factories = @cetas_core.all_provider_factories(ctx, settings)
  let snapshot = @cetas_core.read_credential_snapshot(
    store,
    factories,
    settings~,
    label=self.label,
  ) catch {
    _ => return
  }
  let cached_models = match
    @cetas_core.read_model_list_cache(self.fs, home=self.home) {
    Ok(entries) => entries.get(provider_id)
    Err(_) => None
  }
  for factory in factories {
    if factory.provider_id() != provider_id {
      continue
    }
    let catalog = match
      @cetas_core.try_build_provider_catalog(factory, snapshot, cached_models~) {
      Ok(catalog) => catalog
      Err(_) => return
    }
    match catalog {
      Some(value) => {
        let slots = value.slots()
        for _, workspace in self.workspaces {
          for _, handle in workspace.handles {
            handle.router.replace_provider_slots(provider_id, slots) catch {
              _ => ()
            }
            // The router may have healed a pending selection while installing
            // the provider's slots; the console's per-handle mirror follows the
            // router here exactly as `switch_model` keeps it in step.
            handle.model = handle.router.active_slot_id()
            handle.effort = handle.router.active_effort().unwrap_or("default")
          }
        }
      }
      None => ()
    }
    return
  }
}

///|
/// Sign in to one provider and report the outcome as JSON.
///
/// The steps mirror `cetas-js`: load `settings.providers`, resolve the auth
/// method through cetas-core when the host passed none (an ambiguous provider
/// fails, so the caller picks), run the provider-owned flow through
/// `HubAuthUi`, persist the returned tagged credential through
/// `FileProviderCredentialStore`, refresh the provider's catalog, and answer
/// with `@cetas_core.login_outcome_json`. Secrets never appear in the reply;
/// only the tagged credential reaches the store.
///
/// `device_id` stays empty: this host has no crypto surface, so a provider that
/// needs persistent device identity mints a local one, exactly as
/// `build_cetas_platform` does for its own composition.
///
/// Blocks while a prompt is open, so an adaptor must call it off its command
/// loop (see `spawn_background`) — otherwise the `ui_response` that ends the
/// prompt can never be delivered.
pub async fn ConsoleRuntime::login(
  self : ConsoleRuntime,
  provider : String,
  auth_method : String,
) -> String {
  if !provider_id_is_valid(provider) {
    return login_failure_json(
      provider,
      auth_method,
      "invalid provider id: " + provider,
    )
  }
  let settings = @cetas_core.load_provider_settings(
    self.fs,
    home=self.home,
    label=self.label,
  ) catch {
    _ =>
      return login_failure_json(
        provider, auth_method, "cannot read provider settings from .cetas/settings.json",
      )
  }
  let selected = @cetas_core.resolve_login_method(
    provider,
    auth_method,
    settings~,
  ) catch {
    error => return login_failure_json(provider, auth_method, error.to_string())
  }
  let auth = HubAuthUi::HubAuthUi(
    HubUiPort::new(self.hub, self.ui_registry, self.active_session_id()),
  )
  let outcome = @cetas_core.login_provider(
    provider,
    selected,
    settings~,
    device_id="",
    auth as &@oauth.AuthInteraction,
    auth as &@oauth.AuthPromptInteraction,
  ) catch {
    error => return login_failure_json(provider, selected, error.to_string())
  }
  credential_store(self.fs, self.home).write(
    outcome.provider_id,
    outcome.credential,
  ) catch {
    error =>
      return login_failure_json(
        provider,
        selected,
        "authentication completed, but the credential could not be saved: " +
        @cetas_core.oauth_error_text(error),
      )
  }
  self.install_provider_catalog(outcome.provider_id, settings)
  @cetas_core.login_outcome_json(outcome)
}

///|
/// Sign out of one provider: delete `<credentials>/<provider>.json` through the
/// same store `login` writes with, and report whether a record was removed.
///
/// Deleting an absent record is a successful logout, not an error: the outcome
/// only tells the host whether it should stop showing the provider as signed
/// in. The owning routers are left alone; a catalog built from a credential
/// that no longer exists stops resolving on the next composition, and an
/// in-flight turn keeps the credential it already resolved.
pub async fn ConsoleRuntime::logout(
  self : ConsoleRuntime,
  provider : String,
) -> String {
  if !provider_id_is_valid(provider) {
    return logout_failure_json(provider, "invalid provider id: " + provider)
  }
  let path = @cetas_core.credentials_path(self.home) + "/" + provider + ".json"
  let present = self.fs.exists(path) catch { _ => false }
  credential_store(self.fs, self.home).delete(provider) catch {
    error =>
      return logout_failure_json(
        provider,
        "cannot delete the stored credential: " +
        @cetas_core.oauth_error_text(error),
      )
  }
  logout_outcome_json(provider, present)
}

///|
/// `<Provider> / <model>` → `<Provider>`: the display name a provider's own
/// model-slot labels carry (cetas-web's settings dialog reads provider names
/// the same way). A label without the separator carries no provider title.
fn provider_label_title(label : String) -> String {
  match label.find("/") {
    Some(at) => label[:at].trim().to_owned()
    None => ""
  }
}

///|
/// The GUI's provider inventory: one row per provider that can be signed in to,
/// in registration order — every API-key factory first, then the OAuth
/// registry's remaining ids. `methods` is deduped and always ordered
/// `["api_key", "oauth"]`, so a host can render "Sign in with…" without sorting.
///
/// The registry is the same one `login` resolves against
/// (`@cetas_core.all_api_key_factories`, `oauth_factories`), so settings-derived
/// OpenAI-compatible ids appear exactly as they do at login. Nothing here is
/// hardcoded and nothing is guessed.
fn provider_inventory(
  settings : Map[String, Json],
) -> Array[(String, Array[String])] {
  let ctx = @devkit.ExtContext::default()
  let ids : Array[String] = []
  let methods : Array[Array[String]] = []
  let add = fn(provider_id : String, auth_method : String) {
    let mut at = -1
    for index in 0..<ids.length() {
      if ids[index] == provider_id {
        at = index
      }
    }
    if at < 0 {
      ids.push(provider_id)
      methods.push([auth_method])
    } else if !methods[at].contains(auth_method) {
      methods[at].push(auth_method)
    }
  }
  for factory in @cetas_core.all_api_key_factories(ctx, settings) {
    add(factory.provider_id(), "api_key")
  }
  for factory in @cetas_core.oauth_factories(ctx) {
    add(factory.provider_id(), "oauth")
  }
  let rows : Array[(String, Array[String])] = []
  for index in 0..<ids.length() {
    rows.push((ids[index], methods[index]))
  }
  rows
}

///|
/// Display names for the providers in the inventory, keyed by provider id.
///
/// The provider registry carries ids only, so the human name is taken from the
/// provider's own catalog: slot labels are namespaced `<Provider> / <model>`
/// (see `provider_label_title`). The catalog build is the pure static path —
/// the same one workspace composition uses, with no network request — so a
/// provider that is registered but not yet signed in simply has no label, and
/// the caller falls back to the id.
async fn ConsoleRuntime::provider_display_names(
  self : ConsoleRuntime,
  rows : Array[(String, Array[String])],
  settings : Map[String, Json],
) -> Map[String, String] {
  let names : Map[String, String] = Map::from_array([])
  let wanted : Map[String, Unit] = Map::from_array([])
  for row in rows {
    wanted[row.0] = ()
  }
  let store = credential_store(self.fs, self.home)
  let factories = @cetas_core.all_provider_factories(
    @devkit.ExtContext::default(),
    settings,
  )
  let snapshot = @cetas_core.read_credential_snapshot(
    store,
    factories,
    settings~,
    label=self.label,
  ) catch {
    _ => return names
  }
  for factory in factories {
    let provider_id = factory.provider_id()
    if !wanted.contains(provider_id) || names.contains(provider_id) {
      continue
    }
    let catalog = match
      @cetas_core.try_build_provider_catalog(factory, snapshot) {
      Ok(catalog) => catalog
      Err(_) => continue
    }
    match catalog {
      Some(value) =>
        for slot in value.slots() {
          let title = provider_label_title(slot.label)
          if title != "" {
            names[provider_id] = title
            break
          }
        }
      None => ()
    }
  }
  names
}

///|
/// One inventory row as the GUI reads it: `{id, name, signed_in, methods}`.
/// `name` already carries the id fallback and `methods` the registry order, so
/// this is pure assembly.
fn provider_row_json(
  provider_id : String,
  name : String,
  signed_in : Bool,
  methods : Array[String],
) -> Json {
  let method_json : Array[Json] = []
  for auth_method in methods {
    method_json.push(Json::string(auth_method))
  }
  Json::object(
    Map::from_array([
      ("id", Json::string(provider_id)),
      ("name", Json::string(name)),
      ("signed_in", Json::boolean(signed_in)),
      ("methods", Json::array(method_json)),
    ]),
  )
}

///|
/// Provider inventory for the GUI: who can be signed in to, how, and whether a
/// credential record is stored. This is what a host needs to show "Sign in"
/// versus "Sign out" per provider, and it is the read-only counterpart of
/// `login` / `logout`.
///
/// Each row is `{id, name, signed_in, methods}`: `id` is the value
/// `login` / `logout` take, `name` is the provider's catalog title (the id when
/// the provider has no catalog yet), `methods` lists `"api_key"` / `"oauth"` in
/// that order, and `signed_in` is a real read of the credential store
/// (`<home>/.cetas/credentials/<id>.json`) — a missing, empty or unreadable
/// record reports `false`, so a corrupt record offers a fresh sign-in instead of
/// hiding the problem. Token expiry is the provider's business and is not
/// evaluated here.
///
/// Safe to call at any time: it never prompts, never writes, and never touches
/// the network. Unreadable provider settings degrade to "no settings-derived
/// providers" rather than an error, because the static registry stays listable.
pub async fn ConsoleRuntime::providers_json(self : ConsoleRuntime) -> Json {
  let settings = @cetas_core.load_provider_settings(
    self.fs,
    home=self.home,
    label=self.label,
  ) catch {
    _ => Map::from_array([])
  }
  let rows = provider_inventory(settings)
  let names = self.provider_display_names(rows, settings)
  let store = credential_store(self.fs, self.home)
  let providers : Array[Json] = []
  for row in rows {
    let (provider_id, methods) = row
    let stored : @oauth.ProviderCredential? = store.read(provider_id) catch {
      _ => None
    }
    providers.push(
      provider_row_json(
        provider_id,
        match names.get(provider_id) {
          Some(title) => title
          None => provider_id
        },
        stored is Some(_),
        methods,
      ),
    )
  }
  Json::object(Map::from_array([("providers", Json::array(providers))]))
}
