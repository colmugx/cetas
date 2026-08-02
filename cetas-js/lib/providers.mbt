///|
/// Provider composition for cetas-js.
///
/// Cetas owns only generic sources (the settings JSON and credential files)
/// and registration of public provider-extension seams. Provider extensions
/// receive an opaque `ProviderConfigSource` and own defaults, endpoint/path
/// handling, protocol, model capabilities, and OAuth credential rebuilding.
/// There is deliberately no provider-id switch or legacy environment fallback
/// in this package.

///|
/// A Bun-backed unified credential store. Tokens and API keys are persisted
/// below the Cetas settings directory and are never returned to TypeScript.
///
/// The filename is the provider's public canonical id (the value returned by
/// `ProviderFactory::provider_id`).  The record itself carries an explicit
/// method tag, so a provider which supports both OAuth and API keys has one
/// durable source of truth across recomposition and process restarts.
struct JsProviderCredentialStore {
  cwd : String
}

///|
/// Result of reading a host-owned settings or credential file.  Missing is
/// intentionally distinct from Failed: only an absent optional source may be
/// treated as "not configured".  Permission, directory, and other filesystem
/// failures must remain observable at the composition boundary.
priv enum JsFileReadResult {
  Missing
  Content(String)
  Failed(String)
}

///|
fn JsProviderCredentialStore::new(cwd : String) -> JsProviderCredentialStore {
  { cwd, }
}

///|
fn credential_path(
  store : JsProviderCredentialStore,
  provider_id : String,
) -> String {
  store.cwd + "/.cetas/credentials/" + provider_id + ".json"
}

///|
/// Legacy API-key records were written to a separate filename before the
/// unified store existed.  It is read only during one-way migration.
fn legacy_api_key_credential_path(
  store : JsProviderCredentialStore,
  provider_id : String,
) -> String {
  store.cwd + "/.cetas/credentials/" + provider_id + ".api-key.json"
}

///|
/// Convert the tagged credential to the shared ext-oauth persistence record.
/// The community contract uses `{method, credential}`; the reader below also
/// accepts the early `{type, ...}` experiment so existing previews migrate
/// without guessing.
fn provider_credential_to_json(credential : @oauth.ProviderCredential) -> Json {
  credential.to_json()
}

///|
/// Parse one tagged credential.  `None` means the object has no method tag and
/// may therefore be a legacy OAuth record; malformed tagged records raise a
/// typed composition error without including secret values.
fn parse_tagged_provider_credential(
  json : Json,
  provider_id : String,
) -> @oauth.ProviderCredential? raise @posoco.CompositionError {
  match @oauth.ProviderCredential::from_json(json) {
    Some(value) => return Some(value)
    None => ()
  }
  let fields = match json {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-js.credentials",
        detail="credential file must contain an object for provider " +
          provider_id,
      )
  }
  let kind = match fields.get("type") {
    None => return None
    Some(Json::String(value)) => value
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-js.credentials",
        detail="credential type must be a string for provider " + provider_id,
      )
  }
  // Accept both flattened records (the current writer) and nested payloads
  // (the pre-release migration format), keeping the storage contract tolerant
  // without exposing provider-specific parsing to the host.
  let payload = match fields.get("credential") {
    Some(value) => value
    None => json
  }
  match kind {
    "oauth" =>
      match @oauth.Credential::from_json(payload) {
        Some(value) => Some(@oauth.ProviderCredential::OAuth(value))
        None =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="cetas-js.credentials",
            detail="credential file has an invalid OAuth shape for provider " +
              provider_id,
          )
      }
    "api_key" =>
      match @oauth.ApiKeyCredential::from_json(payload) {
        Some(value) => Some(@oauth.ProviderCredential::ApiKey(value))
        None =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="cetas-js.credentials",
            detail="credential file has an invalid API-key shape for provider " +
              provider_id,
          )
      }
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-js.credentials",
        detail="credential file has an unsupported method for provider " +
          provider_id,
      )
  }
}

///|
/// Read the legacy API-key sidecar and return a typed value.  Error details
/// contain only provider ids and stable shape diagnostics, never secret text.
fn read_legacy_api_key_credential(
  store : JsProviderCredentialStore,
  provider_id : String,
) -> @oauth.ApiKeyCredential? raise @posoco.CompositionError {
  match read_file_sync(legacy_api_key_credential_path(store, provider_id)) {
    Missing => None
    Failed(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-js.credentials",
        detail="legacy API-key credential read failed for provider " +
          provider_id +
          ": " +
          message,
      )
    Content(text) => {
      let json = @json.parse(text) catch {
        _ =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="cetas-js.credentials",
            detail="legacy API-key credential file is not valid JSON for provider " +
              provider_id,
          )
      }
      match @oauth.ApiKeyCredential::from_json(json) {
        Some(value) => Some(value)
        None =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="cetas-js.credentials",
            detail="legacy API-key credential file has an invalid shape for provider " +
              provider_id,
          )
      }
    }
  }
}

///|
/// Read, validate, and if safe migrate a provider's old credential records.
/// The OAuth filename is also the new canonical filename, so an old OAuth
/// object is replaced in place with a tagged record.  An API-key-only sidecar
/// is copied to the canonical file.  When both old records are valid we stop
/// with a typed ambiguity error; explicit `/login provider method` can then
/// replace the canonical record and recover without guessing.
fn read_provider_credential(
  store : JsProviderCredentialStore,
  provider_id : String,
) -> @oauth.ProviderCredential? raise @posoco.CompositionError {
  let path = credential_path(store, provider_id)
  match read_file_sync(path) {
    Missing =>
      match read_legacy_api_key_credential(store, provider_id) {
        None => None
        Some(value) => {
          let credential = @oauth.ProviderCredential::ApiKey(value)
          persist_provider_credential(store, provider_id, credential) catch {
            err =>
              raise @posoco.CompositionError::ManifestSchemaError(
                manifest_id="cetas-js.credentials",
                detail="legacy credential migration failed for provider " +
                  provider_id +
                  ": " +
                  oauth_error_text(err),
              )
          }
          Some(credential)
        }
      }
    Failed(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-js.credentials",
        detail="credential read failed for provider " +
          provider_id +
          ": " +
          message,
      )
    Content(text) => {
      let json = @json.parse(text) catch {
        _ =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="cetas-js.credentials",
            detail="credential file is not valid JSON for provider " +
              provider_id,
          )
      }
      match parse_tagged_provider_credential(json, provider_id) {
        Some(value) => {
          // A canonical tagged record is authoritative, but a stale legacy
          // sidecar must not survive it. Retry cleanup on every read and
          // surface a typed composition error if the filesystem refuses it.
          cleanup_legacy_sidecar(store, provider_id) catch {
            err =>
              raise @posoco.CompositionError::ManifestSchemaError(
                manifest_id="cetas-js.credentials",
                detail="legacy credential cleanup failed for provider " +
                  provider_id +
                  ": " +
                  oauth_error_text(err),
              )
          }
          Some(value)
        }
        None => {
          // Untagged canonical-path data is the legacy OAuth shape.  If a
          // valid API-key sidecar also exists, do not silently choose OAuth.
          let oauth = match @oauth.Credential::from_json(json) {
            Some(value) => value
            None =>
              raise @posoco.CompositionError::ManifestSchemaError(
                manifest_id="cetas-js.credentials",
                detail="credential file has an invalid legacy shape for provider " +
                  provider_id,
              )
          }
          match read_legacy_api_key_credential(store, provider_id) {
            Some(_) =>
              raise @posoco.CompositionError::ManifestSchemaError(
                manifest_id="cetas-js.credentials",
                detail="ambiguous credentials for provider " +
                  provider_id +
                  "; run /login " +
                  provider_id +
                  " oauth or api_key",
              )
            None => {
              let credential = @oauth.ProviderCredential::OAuth(oauth)
              persist_provider_credential(store, provider_id, credential) catch {
                err =>
                  raise @posoco.CompositionError::ManifestSchemaError(
                    manifest_id="cetas-js.credentials",
                    detail="legacy credential migration failed for provider " +
                      provider_id +
                      ": " +
                      oauth_error_text(err),
                  )
              }
              Some(credential)
            }
          }
        }
      }
    }
  }
}

///|
/// Persist one tagged record with an atomic same-directory replace.  The
/// native host never sees the opaque payload and the old record remains intact
/// if writing or renaming the temporary file fails.
fn persist_provider_credential(
  store : JsProviderCredentialStore,
  provider_id : String,
  credential : @oauth.ProviderCredential,
) -> Unit raise @oauth.OAuthError {
  bun_mkdir_sync(store.cwd + "/.cetas/credentials")
  let ok = bun_write_file_atomic(
    credential_path(store, provider_id),
    provider_credential_to_json(credential).stringify(),
  )
  if !ok {
    raise @oauth.OAuthError::HttpError(
      "credential persistence failed for provider " + provider_id,
    )
  }
  // Once the canonical replace is durable, remove legacy sidecars.  This is
  // deliberately ordered after the atomic write: a cleanup failure is
  // observable and retried on the next read/login, but it can never destroy
  // the last known-good canonical record first.
  cleanup_legacy_sidecar(store, provider_id)
}

///|
fn cleanup_legacy_sidecar(
  store : JsProviderCredentialStore,
  provider_id : String,
) -> Unit raise @oauth.OAuthError {
  let ok = bun_delete_file(legacy_api_key_credential_path(store, provider_id))
  if !ok {
    raise @oauth.OAuthError::HttpError(
      "legacy credential cleanup failed for provider " + provider_id,
    )
  }
}

///|
pub impl @oauth.ProviderCredentialStore for JsProviderCredentialStore with fn read(
  self : JsProviderCredentialStore,
  provider_id : String,
) -> @oauth.ProviderCredential? raise @oauth.OAuthError {
  // Router login reads only the canonical tagged record.  Legacy conversion
  // belongs to setup composition (`read_provider_credential`) so a missing
  // router slot cannot accidentally reinterpret two old files.
  match read_file_sync(credential_path(self, provider_id)) {
    Missing => None
    Failed(message) =>
      raise @oauth.OAuthError::HttpError(
        "credential read failed for provider " + provider_id + ": " + message,
      )
    Content(text) => {
      let json = @json.parse(text) catch {
        _ =>
          raise @oauth.OAuthError::ParseError(
            "credential file is not valid JSON for provider " + provider_id,
          )
      }
      let parsed = parse_tagged_provider_credential(json, provider_id) catch {
        _ =>
          raise @oauth.OAuthError::ParseError(
            "credential file has an invalid tagged shape for provider " +
            provider_id,
          )
      }
      match parsed {
        Some(value) => {
          cleanup_legacy_sidecar(self, provider_id) catch {
            err => raise @oauth.OAuthError::HttpError(oauth_error_text(err))
          }
          Some(value)
        }
        None =>
          raise @oauth.OAuthError::ParseError(
            "credential file is an untagged legacy record for provider " +
            provider_id,
          )
      }
    }
  }
}

///|
pub impl @oauth.ProviderCredentialStore for JsProviderCredentialStore with fn write(
  self : JsProviderCredentialStore,
  provider_id : String,
  credential : @oauth.ProviderCredential,
) -> Unit raise @oauth.OAuthError {
  persist_provider_credential(self, provider_id, credential)
}

///|
pub impl @oauth.ProviderCredentialStore for JsProviderCredentialStore with fn delete(
  self : JsProviderCredentialStore,
  provider_id : String,
) -> Unit raise @oauth.OAuthError {
  // Remove the legacy source first.  If cleanup is refused, leave the
  // canonical record intact so a failed logout cannot make the old sidecar
  // reappear as a fresh credential on the next setup read.
  cleanup_legacy_sidecar(self, provider_id)
  let ok = bun_delete_file(credential_path(self, provider_id))
  if !ok {
    raise @oauth.OAuthError::HttpError(
      "credential deletion failed for provider " + provider_id,
    )
  }
}

///|
/// OAuth interaction adapter. Notifications are structured observer custom
/// events so the pi-tui host can render them without the provider knowing the
/// UI library.
struct JsAuthInteraction {
  observer_callback : JsCallback
  request_callback : JsUiRequestCallback
  cancel_check : JsCancelCheck
}

///|
fn JsAuthInteraction::new(
  observer_callback : JsCallback,
  request_callback : JsUiRequestCallback,
  cancel_check : JsCancelCheck,
) -> JsAuthInteraction {
  { observer_callback, request_callback, cancel_check }
}

///|
fn auth_message_json(message : @oauth.AuthMessage) -> String {
  let fields : Array[(String, Json)] = [
    ("type", Json::string("custom")),
    ("source", Json::string("cetas.oauth")),
  ]
  match message {
    @oauth.AuthMessage::AuthUrl(url) => {
      fields.push(("label", Json::string("auth_url")))
      fields.push(
        ("data", Json::object(Map::from_array([("url", Json::string(url))]))),
      )
    }
    @oauth.AuthMessage::DeviceCode(uri, code) => {
      fields.push(("label", Json::string("device_code")))
      fields.push(
        (
          "data",
          Json::object(
            Map::from_array([
              ("verification_uri", Json::string(uri)),
              ("user_code", Json::string(code)),
            ]),
          ),
        ),
      )
    }
    @oauth.AuthMessage::Progress(progress) => {
      fields.push(("label", Json::string("progress")))
      fields.push(
        (
          "data",
          Json::object(Map::from_array([("message", Json::string(progress))])),
        ),
      )
    }
  }
  Json::object(Map::from_array(fields)).stringify()
}

///|
pub impl @oauth.AuthInteraction for JsAuthInteraction with fn notify(
  self : JsAuthInteraction,
  message : @oauth.AuthMessage,
) -> Unit {
  self.observer_callback.invoke(auth_message_json(message))
}

///|
pub impl @oauth.AuthInteraction for JsAuthInteraction with fn is_cancelled(
  self : JsAuthInteraction,
) -> Bool {
  self.cancel_check.is_cancelled()
}

///|
/// Serialize provider-owned prompts without interpreting provider ids or
/// credential formats. The request callback returns only the selected option
/// id or the secret text; secrets never pass through an observer event.
fn auth_prompt_json(request : @oauth.AuthPromptRequest) -> String {
  match request {
    @oauth.AuthPromptRequest::Secret(message~) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("auth_prompt")),
          (
            "request",
            Json::object(
              Map::from_array([
                ("type", Json::string("secret")),
                ("message", Json::string(message)),
              ]),
            ),
          ),
        ]),
      ).stringify()
    @oauth.AuthPromptRequest::Select(message~, options~) => {
      let option_json : Array[Json] = []
      for option in options {
        let fields : Array[(String, Json)] = [
          ("id", Json::string(option.id)),
          ("label", Json::string(option.label)),
        ]
        match option.description {
          Some(description) =>
            fields.push(("description", Json::string(description)))
          None => ()
        }
        option_json.push(Json::object(Map::from_array(fields)))
      }
      Json::object(
        Map::from_array([
          ("type", Json::string("auth_prompt")),
          (
            "request",
            Json::object(
              Map::from_array([
                ("type", Json::string("select")),
                ("message", Json::string(message)),
                ("options", Json::array(option_json)),
              ]),
            ),
          ),
        ]),
      ).stringify()
    }
  }
}

///|
pub impl @oauth.AuthPromptInteraction for JsAuthInteraction with fn prompt(
  self : JsAuthInteraction,
  request : @oauth.AuthPromptRequest,
) -> String raise @oauth.OAuthError {
  self.request_callback.invoke(auth_prompt_json(request)).wait() catch {
    err => {
      let message = err.to_string()
      if message.contains("authentication prompt cancelled") {
        raise @oauth.OAuthError::Cancelled
      }
      raise @oauth.OAuthError::HttpError(
        "authentication prompt callback failed: " + message,
      )
    }
  }
}

///|
/// Generic settings source. It validates only the outer shape and preserves
/// each provider object as opaque JSON for its registered extension factory.
fn load_provider_settings(
  runtime : CetasJsRuntime,
) -> Map[String, Json] raise @posoco.CompositionError {
  let settings_path = runtime.config.cwd + "/.cetas/settings.json"
  match read_file_sync(settings_path) {
    Missing => Map::from_array([])
    Failed(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-js.providers",
        detail=".cetas/settings.json read failed: " + message,
      )
    Content(text) => {
      let json = @json.parse(text) catch {
        _ =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="cetas-js.providers",
            detail=".cetas/settings.json is not valid JSON",
          )
      }
      match json {
        Json::Object(fields) =>
          match fields.get("providers") {
            None => Map::from_array([])
            Some(Json::Object(providers)) => providers
            Some(_) =>
              raise @posoco.CompositionError::ManifestSchemaError(
                manifest_id="cetas-js.providers",
                detail="settings.providers must be an object",
              )
          }
        _ =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="cetas-js.providers",
            detail=".cetas/settings.json must be an object",
          )
      }
    }
  }
}

///|
fn provider_factories(ctx : @devkit.ExtContext) -> Array[&@llm.ProviderFactory] {
  let deepseek = @deepseek.DeepSeekProvider::new(ctx~)
  let kimi = @kimi.KimiProvider::new(ctx~)
  let openai = @openai.OpenAIProvider::new()
  [
    deepseek as &@llm.ProviderFactory,
    kimi as &@llm.ProviderFactory,
    openai as &@llm.ProviderFactory,
  ]
}

///|
fn api_key_factories(ctx : @devkit.ExtContext) -> Array[&@llm.ApiKeyFactory] {
  let deepseek = @deepseek.DeepSeekProvider::new(ctx~)
  let kimi = @kimi.KimiProvider::new(ctx~)
  let openai = @openai.OpenAIProvider::new()
  [
    deepseek as &@llm.ApiKeyFactory,
    kimi as &@llm.ApiKeyFactory,
    openai as &@llm.ApiKeyFactory,
  ]
}

///|
fn oauth_factories(ctx : @devkit.ExtContext) -> Array[&@llm.OAuthFactory] {
  let kimi = @kimi.KimiProvider::new(ctx~)
  let openai = @openai.OpenAIProvider::new()
  [kimi as &@llm.OAuthFactory, openai as &@llm.OAuthFactory]
}

///|
/// Optional live model-discovery seams. Providers that do not implement this
/// contract still participate through their pure static `build` snapshot;
/// Cetas never invents an endpoint or a fallback request for them.
fn refreshable_factories(
  ctx : @devkit.ExtContext,
) -> Array[&@llm.RefreshableProviderFactory] {
  let deepseek = @deepseek.DeepSeekProvider::new(ctx~)
  let kimi = @kimi.KimiProvider::new(ctx~)
  let openai = @openai.OpenAIProvider::new()
  [
    deepseek as &@llm.RefreshableProviderFactory,
    kimi as &@llm.RefreshableProviderFactory,
    openai as &@llm.RefreshableProviderFactory,
  ]
}

///|
fn validate_provider_settings(
  settings : Map[String, Json],
  factories : Array[&@llm.ProviderFactory],
) -> Unit raise @posoco.CompositionError {
  for provider_id, _value in settings {
    let mut known = false
    for factory in factories {
      if factory.provider_id() == provider_id {
        known = true
      }
    }
    if !known {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-js.providers",
        detail="no registered provider extension for settings.providers." +
          provider_id,
      )
    }
  }
}

///|
fn source_for_factory(
  factory : &@llm.ProviderFactory,
  settings : Map[String, Json],
  store : JsProviderCredentialStore,
) -> @llm.ProviderConfigSource raise @posoco.CompositionError {
  let provider_id = factory.provider_id()
  let provider_settings = match settings.get(provider_id) {
    Some(value) => Some(value)
    None => None
  }
  let provider_credential = read_provider_credential(store, provider_id)
  @llm.ProviderConfigSource::ProviderConfigSource(
    settings=provider_settings,
    provider_credential~,
  )
}

///|
/// Ask registered provider extensions for ready catalogs.  `requested` is a
/// provider-id subset for an explicit refresh; `force` means those providers
/// are rebuilt even when a process-lifetime cached catalog exists.  Every
/// other call reuses its cached provider catalog, so setup discovery, Agent
/// recomposition, and `/model` never trigger an implicit second fetch.
async fn collect_provider_catalogs(
  runtime : CetasJsRuntime,
  requested : Array[String]?,
  force : Bool,
) -> Array[@llm.ProviderModelCatalog] raise @posoco.CompositionError {
  let settings = load_provider_settings(runtime)
  let factories = provider_factories(@devkit.ExtContext::default())
  validate_provider_settings(settings, factories)
  let store = JsProviderCredentialStore::new(runtime.config.cwd)
  for factory in factories {
    let provider_id = factory.provider_id()
    let selected = match requested {
      None => true
      Some(ids) => ids.contains(provider_id)
    }
    let should_build = (force && selected) ||
      !runtime.catalog_cache.contains(provider_id)
    if should_build && (selected || requested is None) {
      let source = source_for_factory(factory, settings, store)
      let mut refreshed : @llm.ProviderBuildResult? = None
      if force && selected {
        for
          refresh_factory in refreshable_factories(
            @devkit.ExtContext::default(),
          ) {
          if refresh_factory.provider_id() == provider_id {
            refreshed = Some(refresh_factory.refresh(source))
          }
        }
      }
      let result = match refreshed {
        Some(value) => value
        None => factory.build(source)
      }
      match result {
        @llm.ProviderBuildResult::Ready(catalog) =>
          runtime.catalog_cache[provider_id] = catalog
        @llm.ProviderBuildResult::Unconfigured =>
          runtime.catalog_cache.remove(provider_id)
      }
    }
  }
  let catalogs : Array[@llm.ProviderModelCatalog] = []
  for factory in factories {
    match runtime.catalog_cache.get(factory.provider_id()) {
      Some(catalog) => catalogs.push(catalog)
      None => ()
    }
  }
  catalogs
}

///|
/// Use the process cache without forcing a network/model discovery refresh.
async fn cached_provider_catalogs(
  runtime : CetasJsRuntime,
) -> Array[@llm.ProviderModelCatalog] raise @posoco.CompositionError {
  collect_provider_catalogs(runtime, None, false)
}

///|
async fn build_provider_router(
  runtime : CetasJsRuntime,
  store : JsProviderCredentialStore,
  auth : JsAuthInteraction,
) -> @llm.RouterModelPort raise @posoco.CompositionError {
  let catalogs = cached_provider_catalogs(runtime)
  if catalogs.is_empty() {
    raise @posoco.CompositionError::EmptyPort("cetas-js.providers")
  }
  @llm.RouterModelPort::from_catalogs(
    catalogs,
    provider_credential_store=Some(store as &@oauth.ProviderCredentialStore),
    auth_interaction=Some(auth as &@oauth.AuthInteraction),
    auth_prompt=Some(auth as &@oauth.AuthPromptInteraction),
  )
}

///|
/// Provider capability discovery before Agent composition. It uses exactly the
/// same provider factories as Agent creation, so setup cannot claim a model
/// that later fails a second, divergent provider switch.
async fn provider_setup_json(
  runtime : CetasJsRuntime,
) -> String raise @posoco.CompositionError {
  let catalogs = cached_provider_catalogs(runtime)
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
  let oauth_providers : Array[Json] = []
  for factory in oauth_factories(@devkit.ExtContext::default()) {
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
  // Capability discovery is intentionally independent of ready model slots:
  // an unconfigured provider must still be reachable through `/login`.
  for factory in api_key_factories(@devkit.ExtContext::default()) {
    add_auth_method(factory.provider_id(), "api_key")
  }
  for factory in oauth_factories(@devkit.ExtContext::default()) {
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
/// Parse the provider-neutral refresh selector supplied by the JS bridge. An
/// empty string means all registered providers; otherwise it must be a JSON
/// array of provider ids. Provider ids are validated against the same factory
/// registry used for composition, keeping endpoint/model interpretation out of
/// Cetas.
fn parse_refresh_provider_ids(
  raw : String,
) -> Array[String]? raise @posoco.CompositionError {
  if raw.length() == 0 {
    return None
  }
  let json = @json.parse(raw) catch {
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-js.providers",
        detail="model refresh provider selector is not valid JSON",
      )
  }
  let values = match json {
    Json::Array(values) => values
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-js.providers",
        detail="model refresh provider selector must be an array",
      )
  }
  let factories = provider_factories(@devkit.ExtContext::default())
  let ids : Array[String] = []
  for value in values {
    let provider_id = match value {
      Json::String(value) if value.length() > 0 => value
      _ =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="cetas-js.providers",
          detail="model refresh provider ids must be non-empty strings",
        )
    }
    let mut known = false
    for factory in factories {
      if factory.provider_id() == provider_id {
        known = true
      }
    }
    if !known {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-js.providers",
        detail="no registered provider extension for model refresh: " +
          provider_id,
      )
    }
    if !ids.contains(provider_id) {
      ids.push(provider_id)
    }
  }
  Some(ids)
}

///|
/// Explicit model-catalog refresh used by the application lifecycle. The
/// provider selector is intentionally provider-neutral; factory implementations
/// own all model discovery, endpoint, and response details.
async fn refresh_model_catalogs(
  runtime : CetasJsRuntime,
  provider_ids_json : String,
) -> String raise @posoco.CompositionError {
  let requested = parse_refresh_provider_ids(provider_ids_json)
  let _ = collect_provider_catalogs(runtime, requested, true)
  provider_setup_json(runtime)
}

///|
/// Resolve a missing method only when the registered provider exposes exactly
/// one authentication capability. Ambiguous providers must be selected by
/// the caller's second-level method picker.
fn resolve_login_method(
  provider_id : String,
  requested : String,
) -> String raise @posoco.CommandError {
  if requested.length() > 0 {
    return requested
  }
  let mut has_api_key = false
  for factory in api_key_factories(@devkit.ExtContext::default()) {
    if factory.provider_id() == provider_id {
      has_api_key = true
    }
  }
  let mut has_oauth = false
  for factory in oauth_factories(@devkit.ExtContext::default()) {
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
/// Run provider-owned authentication through the registered public factory
/// seam. Cetas does not know which protocol or endpoint each provider uses.
async fn login_provider(
  runtime : CetasJsRuntime,
  provider_id : String,
  observer_callback : JsCallback,
  request_callback : JsUiRequestCallback,
  cancel_check : JsCancelCheck,
  method : String,
) -> String raise @posoco.CommandError {
  let selected_method = resolve_login_method(provider_id, method)
  let interaction = JsAuthInteraction::new(
    observer_callback, request_callback, cancel_check,
  )
  let store = JsProviderCredentialStore::new(runtime.config.cwd)
  match selected_method {
    "oauth" => {
      let auth_factories = oauth_factories(@devkit.ExtContext::default())
      for factory in auth_factories {
        if factory.provider_id() == provider_id {
          let credential = factory.login(interaction as &@oauth.AuthInteraction) catch {
            err =>
              raise @posoco.CommandError::ExecutionFailed(
                "OAuth login failed for " +
                provider_id +
                ": " +
                oauth_error_text(err),
              )
          }
          let tagged = @oauth.ProviderCredential::OAuth(credential)
          persist_provider_credential(store, factory.provider_id(), tagged) catch {
            err =>
              raise @posoco.CommandError::ExecutionFailed(
                "OAuth credential persistence failed for " +
                provider_id +
                ": " +
                oauth_error_text(err),
              )
          }
          // The tagged record is written first and the legacy sidecar is
          // removed by the persistence helper.  Cleanup failures propagate so
          // setup/login can retry instead of hiding a split-brain store.
          runtime.catalog_cache.remove(provider_id)
          return Json::object(
            Map::from_array([
              ("type", Json::string("success")),
              ("feedback", Json::string("Logged in to " + provider_id)),
              (
                "structured",
                Json::object(
                  Map::from_array([
                    ("provider", Json::string(provider_id)),
                    ("method", Json::string("oauth")),
                  ]),
                ),
              ),
            ]),
          ).stringify()
        }
      }
      raise @posoco.CommandError::ExecutionFailed(
        "no registered OAuth provider: " + provider_id,
      )
    }
    "api_key" => {
      let factories = api_key_factories(@devkit.ExtContext::default())
      for factory in factories {
        if factory.provider_id() == provider_id {
          let credential = factory.login(
            interaction as &@oauth.AuthPromptInteraction,
          ) catch {
            err =>
              raise @posoco.CommandError::ExecutionFailed(
                "API-key login failed for " +
                provider_id +
                ": " +
                oauth_error_text(err),
              )
          }
          let tagged = @oauth.ProviderCredential::ApiKey(credential)
          persist_provider_credential(store, factory.provider_id(), tagged) catch {
            err =>
              raise @posoco.CommandError::ExecutionFailed(
                "API-key credential persistence failed for " +
                provider_id +
                ": " +
                oauth_error_text(err),
              )
          }
          // See the OAuth branch: one tagged canonical file is authoritative;
          // persistence removes the legacy sidecar only after the atomic write.
          runtime.catalog_cache.remove(provider_id)
          return Json::object(
            Map::from_array([
              ("type", Json::string("success")),
              ("feedback", Json::string("Logged in to " + provider_id)),
              (
                "structured",
                Json::object(
                  Map::from_array([
                    ("provider", Json::string(provider_id)),
                    ("method", Json::string("api_key")),
                  ]),
                ),
              ),
            ]),
          ).stringify()
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
fn oauth_error_text(error : @oauth.OAuthError) -> String {
  match error {
    @oauth.OAuthError::AuthPending => "auth_pending"
    @oauth.OAuthError::SlowDown => "slow_down"
    @oauth.OAuthError::AccessDenied => "access_denied"
    @oauth.OAuthError::ExpiredToken => "expired_token"
    @oauth.OAuthError::InvalidGrant => "invalid_grant"
    @oauth.OAuthError::HttpError(detail) => "http_error: " + detail
    @oauth.OAuthError::ParseError(detail) => "parse_error: " + detail
    @oauth.OAuthError::Cancelled => "cancelled"
  }
}

///|
extern "js" fn bun_write_file_atomic(path : String, contents : String) -> Bool =
  #| (path, contents) => {
  #|   const fs = require("fs");
  #|   const suffix = `${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  #|   const tmp = `${path}.tmp-${suffix}`;
  #|   try {
  #|     fs.writeFileSync(tmp, contents, { encoding: "utf8", mode: 0o600 });
  #|     fs.renameSync(tmp, path);
  #|     return true;
  #|   } catch {
  #|     try { fs.unlinkSync(tmp); } catch {}
  #|     return false;
  #|   }
  #| }

///|
extern "js" fn bun_mkdir_sync(path : String) -> Unit =
  #| (path) => { require("fs").mkdirSync(path, { recursive: true }); }

///|
extern "js" fn bun_delete_file(path : String) -> Bool =
  #| (path) => { try { require("fs").unlinkSync(path); return true; } catch (error) { if (error?.code === "ENOENT") return true; return false; } }

///|
/// Synchronously read a generic settings/credential source through Bun FFI.
/// The JS side returns an explicit missing/error distinction so permission and
/// other IO failures cannot be mistaken for an unconfigured provider.
fn read_file_sync(path : String) -> JsFileReadResult {
  let raw = bun_read_file_result(path)
  let json = @json.parse(raw) catch {
    _ => return Failed("file read result is not valid JSON")
  }
  match json {
    Json::Object(fields) =>
      match fields.get("ok") {
        Some(Json::True) =>
          match fields.get("value") {
            Some(Json::String(value)) => Content(value)
            _ => Failed("file read result has no string value")
          }
        Some(Json::False) => {
          let message = match fields.get("error") {
            Some(Json::String(value)) => value
            _ => "unknown filesystem error"
          }
          match fields.get("missing") {
            Some(Json::True) => Missing
            _ => Failed(message)
          }
        }
        _ => Failed("file read result has no ok flag")
      }
    _ => Failed("file read result must be an object")
  }
}

///|
extern "js" fn bun_read_file_result(path : String) -> String =
  #| (path) => {
  #|   const fs = require("fs");
  #|   try {
  #|     return JSON.stringify({ ok: true, value: fs.readFileSync(path, "utf-8") });
  #|   } catch (error) {
  #|     return JSON.stringify({
  #|       ok: false,
  #|       missing: error?.code === "ENOENT",
  #|       error: String(error),
  #|     });
  #|   }
  #| }
