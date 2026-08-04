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
/// so this module performs no IO.
pub(all) struct ProviderCredentialSnapshot {
  settings : Map[String, Json]
  credentials : Map[String, @oauth.ProviderCredential]
}

///|
pub fn ProviderCredentialSnapshot::ProviderCredentialSnapshot(
  settings? : Map[String, Json] = Map::from_array([]),
  credentials? : Map[String, @oauth.ProviderCredential] = Map::from_array([]),
) -> ProviderCredentialSnapshot {
  { settings, credentials }
}

///|
/// Resolve a provider's `ProviderConfigSource` from a snapshot. The factory
/// receives an opaque settings object plus its canonical tagged credential.
pub fn source_for_factory(
  factory : &@llm.ProviderFactory,
  snapshot : ProviderCredentialSnapshot,
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
  )
}

///|
/// Build one provider's catalog snapshot without any network request. This is
/// the pure `ProviderFactory::build` path used by setup discovery and Agent
/// recomposition; live refresh is a separate explicit host action.
pub fn build_provider_catalog(
  factory : &@llm.ProviderFactory,
  snapshot : ProviderCredentialSnapshot,
) -> @llm.ProviderModelCatalog? raise @posoco.CompositionError {
  let source = source_for_factory(factory, snapshot)
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => Some(catalog)
    @llm.ProviderBuildResult::Unconfigured => None
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
pub fn resolve_login_method(
  provider_id : String,
  requested : String,
) -> String raise @posoco.CommandError {
  if requested.length() > 0 {
    return requested
  }
  let ctx = @devkit.ExtContext::default()
  let mut has_api_key = false
  for factory in api_key_factories(ctx) {
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
  method : String
  feedback : String
  credential : @oauth.ProviderCredential
}

///|
/// Run provider-owned authentication through the registered public factory
/// seam. Cetas does not know which protocol or endpoint each provider uses.
///
/// The host supplies the resolved `device_id` (for OAuth factories that need
/// persistent device identity) and the provider's auth interaction impls.
/// Persistence and cache invalidation are the host's responsibility; this
/// function returns the credential to persist.
pub async fn login_provider(
  provider_id : String,
  method : String,
  device_id? : String = "",
  auth_interaction : &@oauth.AuthInteraction,
  auth_prompt : &@oauth.AuthPromptInteraction,
) -> LoginOutcome raise @posoco.CommandError {
  let selected = resolve_login_method(provider_id, method)
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
            method: "oauth",
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
      for factory in api_key_factories(ctx) {
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
            method: "api_key",
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
pub fn provider_setup_json(
  catalogs : Array[@llm.ProviderModelCatalog],
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
  let add_auth_method = fn(provider_id : String, method : String) {
    let mut found = -1
    for i in 0..<auth_provider_ids.length() {
      if auth_provider_ids[i] == provider_id {
        found = i
      }
    }
    if found < 0 {
      auth_provider_ids.push(provider_id)
      auth_methods.push([method])
    } else if !auth_methods[found].contains(method) {
      auth_methods[found].push(method)
    }
  }
  for factory in api_key_factories(ctx) {
    add_auth_method(factory.provider_id(), "api_key")
  }
  for factory in oauth_factories(ctx) {
    add_auth_method(factory.provider_id(), "oauth")
  }
  let auth_entries : Array[Json] = []
  for i in 0..<auth_provider_ids.length() {
    let method_values : Array[Json] = []
    for method in auth_methods[i] {
      method_values.push(Json::string(method))
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
            ("method", Json::string(outcome.method)),
          ]),
        ),
      ),
    ]),
  ).stringify()
}
