///|
/// provider_login.mbt — Provider-neutral login + catalog + setup orchestration.
///
/// This module owns the cross-target orchestration that every cetas host
/// shares: resolving an auth method, running provider-owned login, building
/// model catalogs from settings + credentials, and producing the setup-
/// discovery JSON. It programs only against the public provider extension
/// traits (`ProviderFactory`, `OAuthFactory`, `ApiKeyFactory`,
/// `RefreshableProviderFactory`) and the `@oauth` interaction/credential
/// seams; a host injects concrete trait impls and plain data.
///
/// All functions are side-effect free with respect to storage: a host reads
/// files, mints device ids, persists credentials, and invalidates caches
/// around these calls. The orchestration returns plain data outcomes.

///|
/// A host-supplied credential snapshot keyed by provider id. The host reads
/// its credential store once and hands the whole map to catalog composition,
/// so this module performs no IO. `credential_store` carries the store the
/// credentials were read from so a refresh seam can persist renewed records;
/// `None` keeps renewal memory-only.
pub(all) struct ProviderCredentialSnapshot {
  settings : Map[String, Json]
  credentials : Map[String, @oauth.ProviderCredential]
  credential_store : &@oauth.ProviderCredentialStore?
}

///|
pub fn ProviderCredentialSnapshot::ProviderCredentialSnapshot(
  settings? : Map[String, Json] = Map::from_array([]),
  credentials? : Map[String, @oauth.ProviderCredential] = Map::from_array([]),
  credential_store? : &@oauth.ProviderCredentialStore? = None,
) -> ProviderCredentialSnapshot {
  { settings, credentials, credential_store, }
}

///|
/// Resolve a provider's `ProviderConfigSource` from a snapshot. The factory
/// receives an opaque settings object plus its canonical tagged credential.
/// `cached_models` carries this provider's host-cached discovery records
/// (see `model_cache.mbt`) so the static `build` path can expand a multi-slot
/// catalog offline; providers that do not support expansion ignore it.
pub fn source_for_factory(
  factory : &@llm.ProviderFactory,
  snapshot : ProviderCredentialSnapshot,
  cached_models? : Json? = None,
) -> @llm.ProviderConfigSource {
  let provider_id = factory.provider_id()
  let provider_settings = match snapshot.settings.get(provider_id) {
    Some(value) => Some(value)
    None => None
  }
  let provider_credential = match snapshot.credentials.get(provider_id) {
    Some(value) => Some(value)
    None => None
  }
  @llm.ProviderConfigSource::ProviderConfigSource(
    settings=provider_settings,
    provider_credential~,
    cached_models~,
    credential_store=snapshot.credential_store,
  )
}

///|
/// Build one provider's catalog snapshot without any network request. This is
/// the pure `ProviderFactory::build` path used by setup discovery and Agent
/// recomposition; live refresh is a separate explicit host action.
/// `cached_models` seeds offline expansion exactly as in `source_for_factory`.
pub fn build_provider_catalog(
  factory : &@llm.ProviderFactory,
  snapshot : ProviderCredentialSnapshot,
  cached_models? : Json? = None,
) -> @llm.ProviderModelCatalog? raise @posoco.CompositionError {
  let source = source_for_factory(factory, snapshot, cached_models~)
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => Some(catalog)
    @llm.ProviderBuildResult::Unconfigured => None
  }
}

///|
/// One provider's catalog build failure, isolated so the rest of the
/// assembly stays usable. The host surfaces these as warnings; the provider
/// is simply absent from the model list until its settings or credentials
/// are fixed.
pub(all) struct CatalogBuildIssue {
  provider_id : String
  detail : String
}

///|
/// Build one provider's catalog with failure isolation. A misconfigured
/// provider yields `Err` instead of poisoning the whole assembly: hosts loop
/// over this seam, record the issue, and keep the healthy providers alive.
/// The raising variant remains for single-provider actions that genuinely
/// need fail-fast semantics.
pub fn try_build_provider_catalog(
  factory : &@llm.ProviderFactory,
  snapshot : ProviderCredentialSnapshot,
  cached_models? : Json? = None,
) -> Result[@llm.ProviderModelCatalog?, @posoco.CompositionError] {
  Ok(build_provider_catalog(factory, snapshot, cached_models~)) catch {
    err => Err(err)
  }
}

///|
/// Live-refresh the catalog of one provider through its `refresh` seam, then
/// return its rebuilt snapshot. Used by an explicit model-catalog refresh
/// action; a normal build never issues a network request.
pub async fn refresh_provider_catalog(
  factory : &@llm.RefreshableProviderFactory,
  snapshot : ProviderCredentialSnapshot,
) -> @llm.ProviderModelCatalog? raise @posoco.CompositionError {
  // RefreshableProviderFactory owns its own provider_id; build the source
  // directly so refresh and static build agree on inputs without requiring a
  // trait-to-trait cast.
  let provider_id = factory.provider_id()
  let provider_settings = match snapshot.settings.get(provider_id) {
    Some(value) => Some(value)
    None => None
  }
  let provider_credential = match snapshot.credentials.get(provider_id) {
    Some(value) => Some(value)
    None => None
  }
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=provider_settings,
    provider_credential~,
    credential_store=snapshot.credential_store,
  )
  match factory.refresh(source) {
    @llm.ProviderBuildResult::Ready(catalog) => Some(catalog)
    @llm.ProviderBuildResult::Unconfigured => None
  }
}

///|
/// Resolve a missing method only when the registered provider exposes exactly
/// one authentication capability. Ambiguous providers must be selected by the
/// caller's second-level method picker.
///
/// `settings` makes the lookup settings-aware: any settings.providers key not
/// claimed by a static provider is served by an openai-compatible instance,
/// which offers exactly the api_key method.
pub fn resolve_login_method(
  provider_id : String,
  requested : String,
  settings? : Map[String, Json] = Map::from_array([]),
) -> String raise @posoco.CommandError {
  if requested.length() > 0 {
    return requested
  }
  let ctx = @devkit.ExtContext::default()
  let mut has_api_key = false
  for factory in all_api_key_factories(ctx, settings) {
    if factory.provider_id() == provider_id {
      has_api_key = true
    }
  }
  let mut has_oauth = false
  for factory in oauth_factories(ctx) {
    if factory.provider_id() == provider_id {
      has_oauth = true
    }
  }
  if has_api_key && !has_oauth {
    return "api_key"
  }
  if has_oauth && !has_api_key {
    return "oauth"
  }
  if has_api_key && has_oauth {
    raise @posoco.CommandError::InvalidArgs(
      reason="/login requires method for provider " + provider_id,
    )
  }
  raise @posoco.CommandError::ExecutionFailed(
    "no registered authentication provider: " + provider_id,
  )
}

///|
/// Outcome of a provider login. The host persists the returned credential,
/// invalidates its catalog cache for `provider_id`, and renders the feedback.
/// Secrets never appear here; only the canonical tagged credential flows
/// back to the host's durable store.
pub(all) struct LoginOutcome {
  provider_id : String
  login_method : String
  feedback : String
  credential : @oauth.ProviderCredential
}

///|
/// Run provider-owned authentication through the registered public factory
/// seam. Cetas does not know which protocol or endpoint each provider uses.
///
/// The host supplies the resolved `device_id` (for OAuth factories that need
/// persistent device identity), the provider's auth interaction impls, and the
/// settings map so custom OpenAI-compatible ids resolve through the same
/// settings-aware factory list as catalog composition. Persistence and cache
/// invalidation are the host's responsibility; this function returns the
/// credential to persist.
pub async fn login_provider(
  provider_id : String,
  requested : String,
  settings? : Map[String, Json] = Map::from_array([]),
  device_id? : String = "",
  auth_interaction : &@oauth.AuthInteraction,
  auth_prompt : &@oauth.AuthPromptInteraction,
) -> LoginOutcome raise @posoco.CommandError {
  let selected = resolve_login_method(provider_id, requested, settings~)
  let ctx = @devkit.ExtContext::default()
  match selected {
    "oauth" => {
      for factory in oauth_factories(ctx, device_id~) {
        if factory.provider_id() == provider_id {
          let credential = factory.login(auth_interaction) catch {
            err =>
              raise @posoco.CommandError::ExecutionFailed(
                "OAuth login failed for " +
                provider_id +
                ": " +
                oauth_error_text(err),
              )
          }
          return {
            provider_id,
            login_method: "oauth",
            feedback: "Logged in to " + provider_id,
            credential: @oauth.ProviderCredential::OAuth(credential),
          }
        }
      }
      raise @posoco.CommandError::ExecutionFailed(
        "no registered OAuth provider: " + provider_id,
      )
    }
    "api_key" => {
      for factory in all_api_key_factories(ctx, settings) {
        if factory.provider_id() == provider_id {
          let credential = factory.login(auth_prompt) catch {
            err =>
              raise @posoco.CommandError::ExecutionFailed(
                "API-key login failed for " +
                provider_id +
                ": " +
                oauth_error_text(err),
              )
          }
          return {
            provider_id,
            login_method: "api_key",
            feedback: "Logged in to " + provider_id,
            credential: @oauth.ProviderCredential::ApiKey(credential),
          }
        }
      }
      raise @posoco.CommandError::ExecutionFailed(
        "no registered API-key provider: " + provider_id,
      )
    }
    other =>
      raise @posoco.CommandError::ExecutionFailed(
        "unsupported authentication method: " + other,
      )
  }
}

///|
/// Build the provider setup JSON: the ready model slots, the OAuth-capable
/// provider ids, and the per-provider auth-method matrix. Capability
/// discovery is intentionally independent of ready model slots: an
/// unconfigured provider must still be reachable through `/login`.
///
/// `settings` widens the api-key matrix to settings-derived OpenAI-compatible
/// providers so a configured-but-not-yet-logged-in custom id appears in
/// `authProviders` with `["api_key"]`.
pub fn provider_setup_json(
  catalogs : Array[@llm.ProviderModelCatalog],
  settings? : Map[String, Json] = Map::from_array([]),
  issues? : Array[CatalogBuildIssue] = [],
) -> String {
  let entries : Array[Json] = []
  let mut active_model_id : String? = None
  for catalog in catalogs {
    for slot in catalog.slots() {
      let is_active = active_model_id is None
      if is_active {
        active_model_id = Some(slot.id)
      }
      let efforts : Array[Json] = []
      for effort in slot.thinking_efforts {
        efforts.push(Json::string(effort))
      }
      entries.push(
        Json::object(
          Map::from_array([
            ("id", Json::string(slot.id)),
            ("label", Json::string(slot.label)),
            ("provider", Json::string(slot.provider_id)),
            ("model", Json::string(slot.model_id)),
            ("active", Json::boolean(is_active)),
            ("efforts", Json::array(efforts)),
            ("oauth", Json::boolean(slot.oauth is Some(_))),
          ]),
        ),
      )
    }
  }
  let ctx = @devkit.ExtContext::default()
  let oauth_providers : Array[Json] = []
  for factory in oauth_factories(ctx) {
    oauth_providers.push(Json::string(factory.provider_id()))
  }
  let auth_provider_ids : Array[String] = []
  let auth_methods : Array[Array[String]] = []
  let add_auth_method = fn(provider_id : String, auth_method : String) {
    let mut found = -1
    for i in 0..<auth_provider_ids.length() {
      if auth_provider_ids[i] == provider_id {
        found = i
      }
    }
    if found < 0 {
      auth_provider_ids.push(provider_id)
      auth_methods.push([auth_method])
    } else if !auth_methods[found].contains(auth_method) {
      auth_methods[found].push(auth_method)
    }
  }
  for factory in all_api_key_factories(ctx, settings) {
    add_auth_method(factory.provider_id(), "api_key")
  }
  for factory in oauth_factories(ctx) {
    add_auth_method(factory.provider_id(), "oauth")
  }
  let auth_entries : Array[Json] = []
  for i in 0..<auth_provider_ids.length() {
    let method_values : Array[Json] = []
    for auth_method in auth_methods[i] {
      method_values.push(Json::string(auth_method))
    }
    auth_entries.push(
      Json::object(
        Map::from_array([
          ("provider", Json::string(auth_provider_ids[i])),
          ("methods", Json::array(method_values)),
        ]),
      ),
    )
  }
  let fields : Array[(String, Json)] = [
    ("providers", Json::array(entries)),
    ("oauthProviders", Json::array(oauth_providers)),
    ("authProviders", Json::array(auth_entries)),
  ]
  if !issues.is_empty() {
    let warning_values : Array[Json] = []
    for issue in issues {
      warning_values.push(
        Json::string(
          "provider " + issue.provider_id + " skipped: " + issue.detail,
        ),
      )
    }
    fields.push(("warnings", Json::array(warning_values)))
  }
  match active_model_id {
    Some(value) => fields.push(("activeModelId", Json::string(value)))
    None => ()
  }
  Json::object(Map::from_array(fields)).stringify()
}

///|
/// Encode a `LoginOutcome` as the provider-neutral success JSON consumed by
/// the host's command renderer.
pub fn login_outcome_json(outcome : LoginOutcome) -> String {
  Json::object(
    Map::from_array([
      ("type", Json::string("success")),
      ("feedback", Json::string(outcome.feedback)),
      (
        "structured",
        Json::object(
          Map::from_array([
            ("provider", Json::string(outcome.provider_id)),
            ("method", Json::string(outcome.login_method)),
          ]),
        ),
      ),
    ]),
  ).stringify()
}

///|
/// Provider-neutral interactive login flow shared by native hosts.
///
/// The caller owns presentation through AuthInteraction/AuthPromptInteraction
/// and supplies a device-id mint callback. Cetas-core owns provider/method
/// discovery, credential persistence, catalog refresh/cache, and initial model
/// selection so every host observes one login contract.
pub async fn run_provider_login_flow(
  home~ : String,
  provider~ : String,
  fs : &@workspace.WorkspaceFs,
  interaction : &@oauth.AuthInteraction,
  prompt : &@oauth.AuthPromptInteraction,
  mint_device_id : () -> String raise @posoco.CommandError,
  note? : async (String) -> Unit noraise = fn(_ : String) { () },
) -> Unit raise @posoco.CommandError {
  let settings = load_provider_settings(fs, home~, label="cetas.login") catch {
    _ =>
      raise @posoco.CommandError::ExecutionFailed(
        "Cannot read login provider settings",
      )
  }
  let factories = all_provider_factories(
    @devkit.ExtContext::default(),
    settings,
  )
  validate_provider_settings(settings, factories) catch {
    _ =>
      raise @posoco.CommandError::ExecutionFailed(
        "Invalid login provider settings",
      )
  }
  let active = read_active_model_selection(fs, home~) catch {
    _ =>
      raise @posoco.CommandError::ExecutionFailed(
        "Cannot read persisted model selection",
      )
  }

  let provider_ids : Array[String] = []
  let provider_methods : Array[Array[String]] = []
  let add_method = fn(id : String, auth_method : String) {
    let mut found = -1
    for index in 0..<provider_ids.length() {
      if provider_ids[index] == id {
        found = index
        break
      }
    }
    if found < 0 {
      provider_ids.push(id)
      provider_methods.push([auth_method])
    } else if !provider_methods[found].contains(auth_method) {
      provider_methods[found].push(auth_method)
    }
  }
  let ctx = @devkit.ExtContext::default()
  for factory in all_api_key_factories(ctx, settings) {
    add_method(factory.provider_id(), "api_key")
  }
  for factory in oauth_factories(ctx) {
    add_method(factory.provider_id(), "oauth")
  }

  let select = async fn(
    message : String,
    options : Array[@oauth.AuthPromptOption],
  ) -> String raise @posoco.CommandError {
    if interaction.is_cancelled() {
      raise @posoco.CommandError::ExecutionFailed("Login cancelled")
    }
    let selected = prompt.prompt(
      @oauth.AuthPromptRequest::Select(message~, options~),
    ) catch {
      @oauth.OAuthError::Cancelled =>
        raise @posoco.CommandError::ExecutionFailed("Login cancelled")
      _ => raise @posoco.CommandError::ExecutionFailed("Login selection failed")
    }
    if interaction.is_cancelled() {
      raise @posoco.CommandError::ExecutionFailed("Login cancelled")
    }
    for option in options {
      if option.id == selected {
        return selected
      }
    }
    raise @posoco.CommandError::InvalidArgs(reason="Invalid login selection")
  }

  let selected_provider = if provider.is_empty() {
    let options : Array[@oauth.AuthPromptOption] = []
    for id in provider_ids {
      options.push(@oauth.AuthPromptOption::AuthPromptOption(id~, label=id))
    }
    select("Select login provider", options)
  } else {
    provider
  }

  let methods : Array[String] = []
  for index in 0..<provider_ids.length() {
    if provider_ids[index] == selected_provider {
      methods.append(provider_methods[index])
      break
    }
  }
  if methods.is_empty() {
    raise @posoco.CommandError::InvalidArgs(
      reason="Unknown login provider; select a registered authentication provider",
    )
  }
  let selected_method = if methods.length() == 1 {
    methods[0]
  } else {
    let options : Array[@oauth.AuthPromptOption] = []
    for auth_method in methods {
      options.push(
        @oauth.AuthPromptOption::AuthPromptOption(
          id=auth_method,
          label=if auth_method == "oauth" {
            "OAuth / browser login"
          } else {
            "API key"
          },
        ),
      )
    }
    select("Select authentication method", options)
  }

  let device_id = if selected_provider == "kimi" && selected_method == "oauth" {
    let path = cetas_dir(home) + "/kimi_device_id"
    match @workspace.read_file_result(fs, path) {
      @workspace.Content(text) if !text.trim().is_empty() =>
        text.trim().to_owned()
      @workspace.Failed(_) =>
        raise @posoco.CommandError::ExecutionFailed(
          "Cannot read persistent login device id",
        )
      _ => {
        let id = mint_device_id()
        fs.mkdir(cetas_dir(home), recursive=true) catch {
          _ =>
            raise @posoco.CommandError::ExecutionFailed(
              "Cannot save persistent login device id",
            )
        }
        fs.write_file_atomic(path, id) catch {
          _ =>
            raise @posoco.CommandError::ExecutionFailed(
              "Cannot save persistent login device id",
            )
        }
        id
      }
    }
  } else {
    ""
  }

  let outcome = login_provider(
    selected_provider,
    selected_method,
    settings~,
    device_id~,
    interaction,
    prompt,
  ) catch {
    _ =>
      raise @posoco.CommandError::ExecutionFailed(
        "Authentication failed or was cancelled; credentials were not saved",
      )
  }
  if interaction.is_cancelled() {
    raise @posoco.CommandError::ExecutionFailed("Login cancelled")
  }
  if outcome.provider_id != selected_provider ||
    outcome.login_method != selected_method {
    raise @posoco.CommandError::ExecutionFailed(
      "Authentication returned an inconsistent provider or method",
    )
  }

  let store = @credentials.FileProviderCredentialStore(
    fs,
    credentials_path(home),
  )
  store.write(selected_provider, outcome.credential) catch {
    _ =>
      raise @posoco.CommandError::ExecutionFailed(
        "Authentication completed, but credentials could not be saved; catalog was not refreshed",
      )
  }
  note("Authentication saved for " + selected_provider)

  let snapshot = read_credential_snapshot(
    store,
    factories,
    settings~,
    label="cetas.login",
  ) catch {
    _ =>
      raise @posoco.CommandError::ExecutionFailed(
        "Authentication saved, but credentials could not be reloaded",
      )
  }

  let mut catalog : @llm.ProviderModelCatalog? = None
  let mut refreshable_found = false
  for factory in refreshable_factories(ctx, device_id~) {
    if factory.provider_id() == selected_provider {
      refreshable_found = true
      catalog = refresh_provider_catalog(factory, snapshot) catch {
        _ =>
          raise @posoco.CommandError::ExecutionFailed(
            "Authentication saved for " +
            selected_provider +
            ", but catalog refresh failed; saved credentials were retained",
          )
      }
      break
    }
  }
  if !refreshable_found {
    for factory in all_provider_factories(ctx, settings) {
      if factory.provider_id() == selected_provider {
        catalog = build_provider_catalog(factory, snapshot) catch { _ => None }
        break
      }
    }
  }

  match catalog {
    None =>
      note(
        "Authentication saved, but no model catalog is available; use /model after configuring this provider",
      )
    Some(value) => {
      write_model_list_cache(
        fs,
        home~,
        selected_provider,
        catalog_model_records(value),
      ) catch {
        _ =>
          raise @posoco.CommandError::ExecutionFailed(
            "Authentication saved, but refreshed model catalog could not be cached; saved credentials were retained",
          )
      }
      if active is Some(_) {
        return
      }
      let slots = value.slots()
      if slots.is_empty() {
        note("No models were discovered; use /model after login")
        return
      }
      let selected = if slots.length() == 1 {
        slots[0].id
      } else {
        let options : Array[@oauth.AuthPromptOption] = []
        for slot in slots {
          options.push(
            @oauth.AuthPromptOption::AuthPromptOption(
              id=slot.id,
              label=slot.label,
            ),
          )
        }
        select(
          "Select initial model (authentication is already saved)", options,
        )
      }
      let current = read_active_model_selection(fs, home~) catch {
        _ =>
          raise @posoco.CommandError::ExecutionFailed(
            "Authentication saved, but persisted model selection could not be read",
          )
      }
      if current is None {
        write_active_model_selection(
          fs,
          home~,
          ActiveModelSelection::ActiveModelSelection(selected),
        ) catch {
          _ =>
            raise @posoco.CommandError::ExecutionFailed(
              "Authentication saved, but initial model selection could not be saved",
            )
        }
        note("Initial model saved: " + selected)
      }
    }
  }
}
