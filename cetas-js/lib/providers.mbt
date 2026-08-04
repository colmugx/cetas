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
/// Credential path / parse helpers live in cetas-core. These thin wrappers
/// adapt the host-owned `JsProviderCredentialStore.cwd` to the core signature
/// so the JS credential store impls stay readable.
fn credential_path(
  store : JsProviderCredentialStore,
  provider_id : String,
) -> String {
  @cetas_core.credential_path(store.cwd, provider_id)
}

///|
fn legacy_api_key_credential_path(
  store : JsProviderCredentialStore,
  provider_id : String,
) -> String {
  @cetas_core.legacy_api_key_credential_path(store.cwd, provider_id)
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
                  @cetas_core.oauth_error_text(err),
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
      match @cetas_core.parse_tagged_provider_credential(json, provider_id) {
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
                  @cetas_core.oauth_error_text(err),
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
                      @cetas_core.oauth_error_text(err),
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
    @cetas_core.provider_credential_to_json(credential).stringify(),
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
      let parsed = @cetas_core.parse_tagged_provider_credential(
        json, provider_id,
      ) catch {
        _ =>
          raise @oauth.OAuthError::ParseError(
            "credential file has an invalid tagged shape for provider " +
            provider_id,
          )
      }
      match parsed {
        Some(value) => {
          cleanup_legacy_sidecar(self, provider_id) catch {
            err =>
              raise @oauth.OAuthError::HttpError(
                @cetas_core.oauth_error_text(err),
              )
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
/// Auth message / prompt encoding lives in cetas-core (`auth_message_json`,
/// `auth_prompt_json`); the host forwards the provider-neutral values so every
/// host renders the same observer wire shape.

///|
pub impl @oauth.AuthInteraction for JsAuthInteraction with fn notify(
  self : JsAuthInteraction,
  message : @oauth.AuthMessage,
) -> Unit {
  self.observer_callback.invoke(@cetas_core.auth_message_json(message))
}

///|
pub impl @oauth.AuthInteraction for JsAuthInteraction with fn is_cancelled(
  self : JsAuthInteraction,
) -> Bool {
  self.cancel_check.is_cancelled()
}

///|
pub impl @oauth.AuthPromptInteraction for JsAuthInteraction with fn prompt(
  self : JsAuthInteraction,
  request : @oauth.AuthPromptRequest,
) -> String raise @oauth.OAuthError {
  self.request_callback.invoke(@cetas_core.auth_prompt_json(request)).wait() catch {
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
/// Provider factory wiring, settings validation, and refresh-selector parsing
/// live in cetas-core (`provider_factories`, `api_key_factories`,
/// `oauth_factories`, `refreshable_factories`, `validate_provider_settings`,
/// `parse_refresh_provider_ids`). This host forwards to them so every host
/// shares the single source of truth; the host resolves `device_id`
/// (host-owned persistent storage) and passes it to the OAuth/refresh seams.

///|
/// Read every registered provider's credential once into a snapshot map, so
/// the catalog build loop performs no per-provider file IO. Missing files and
/// unconfigured providers simply map to no entry.
fn read_credential_snapshot(
  store : JsProviderCredentialStore,
) -> Map[String, @oauth.ProviderCredential] raise @posoco.CompositionError {
  let ctx = @devkit.ExtContext::default()
  let credentials : Map[String, @oauth.ProviderCredential] = Map::from_array([])
  for factory in @cetas_core.provider_factories(ctx) {
    let provider_id = factory.provider_id()
    match read_provider_credential(store, provider_id) {
      Some(value) => credentials[provider_id] = value
      None => ()
    }
  }
  credentials
}

///|
/// Ask registered provider extensions for ready catalogs.  `requested` is a
/// provider-id subset for an explicit refresh; `force` means those providers
/// are rebuilt even when a process-lifetime cached catalog exists.  Every
/// other call reuses its cached provider catalog, so setup discovery, Agent
/// recomposition, and `/model` never trigger an implicit second fetch.
///
/// Factory wiring and validation live in cetas-core; this host owns only the
/// process-lifetime cache and the host-specific credential file reads.
async fn collect_provider_catalogs(
  runtime : CetasJsRuntime,
  requested : Array[String]?,
  force : Bool,
) -> Array[@llm.ProviderModelCatalog] raise @posoco.CompositionError {
  let ctx = @devkit.ExtContext::default()
  let settings = load_provider_settings(runtime)
  let factories = @cetas_core.provider_factories(ctx)
  @cetas_core.validate_provider_settings(settings, factories)
  let store = JsProviderCredentialStore::new(runtime.config.cwd)
  let credentials = read_credential_snapshot(store)
  let snapshot = @cetas_core.ProviderCredentialSnapshot::ProviderCredentialSnapshot(
    settings~,
    credentials~,
  )
  let device_id = if runtime.config.cwd.length() > 0 {
    resolve_kimi_device_id(runtime.config.cwd)
  } else {
    ""
  }
  for factory in factories {
    let provider_id = factory.provider_id()
    let selected = match requested {
      None => true
      Some(ids) => ids.contains(provider_id)
    }
    let should_build = (force && selected) ||
      !runtime.catalog_cache.contains(provider_id)
    if should_build && (selected || requested is None) {
      let mut refreshed : @llm.ProviderBuildResult? = None
      if force && selected {
        for
          refresh_factory in @cetas_core.refreshable_factories(ctx, device_id~) {
          if refresh_factory.provider_id() == provider_id {
            match
              @cetas_core.refresh_provider_catalog(refresh_factory, snapshot) {
              Some(catalog) =>
                refreshed = Some(@llm.ProviderBuildResult::Ready(catalog))
              None => refreshed = Some(@llm.ProviderBuildResult::Unconfigured)
            }
          }
        }
      }
      let result = match refreshed {
        Some(value) => value
        None =>
          match @cetas_core.build_provider_catalog(factory, snapshot) {
            Some(catalog) => @llm.ProviderBuildResult::Ready(catalog)
            None => @llm.ProviderBuildResult::Unconfigured
          }
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
/// Provider capability discovery before Agent composition. The setup JSON
/// assembly is provider-neutral and lives in cetas-core; this host only feeds
/// it the cached catalogs.
async fn provider_setup_json(
  runtime : CetasJsRuntime,
) -> String raise @posoco.CompositionError {
  let catalogs = cached_provider_catalogs(runtime)
  @cetas_core.provider_setup_json(catalogs)
}

///|
/// Parse the provider-neutral refresh selector. Validation lives in
/// cetas-core; this host forwards the raw selector unchanged.
fn parse_refresh_provider_ids(
  raw : String,
) -> Array[String]? raise @posoco.CompositionError {
  @cetas_core.parse_refresh_provider_ids(raw)
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
/// Run provider-owned authentication through the cetas-core login seam. Core
/// resolves the method, runs the factory login, and returns a tagged
/// credential outcome; this host performs the host-specific persistence
/// (atomic file write + legacy sidecar cleanup) and invalidates its catalog
/// cache so the next composition sees the new credential.
async fn login_provider(
  runtime : CetasJsRuntime,
  provider_id : String,
  observer_callback : JsCallback,
  request_callback : JsUiRequestCallback,
  cancel_check : JsCancelCheck,
  method : String,
) -> String raise @posoco.CommandError {
  let interaction = JsAuthInteraction::new(
    observer_callback, request_callback, cancel_check,
  )
  let store = JsProviderCredentialStore::new(runtime.config.cwd)
  let device_id = if runtime.config.cwd.length() > 0 {
    resolve_kimi_device_id(runtime.config.cwd)
  } else {
    ""
  }
  let outcome = @cetas_core.login_provider(
    provider_id,
    method,
    device_id~,
    interaction as &@oauth.AuthInteraction,
    interaction as &@oauth.AuthPromptInteraction,
  )
  persist_provider_credential(store, outcome.provider_id, outcome.credential) catch {
    err =>
      raise @posoco.CommandError::ExecutionFailed(
        outcome.method +
        " credential persistence failed for " +
        provider_id +
        ": " +
        @cetas_core.oauth_error_text(err),
      )
  }
  // The tagged record is written first and the legacy sidecar is removed by
  // the persistence helper. Cleanup failures propagate so setup/login can
  // retry instead of hiding a split-brain store.
  runtime.catalog_cache.remove(provider_id)
  @cetas_core.login_outcome_json(outcome)
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

///|
/// Mint a v4 UUID via the host runtime's crypto module (Node / Bun both ship
/// `crypto.randomUUID`). Returns "" only if crypto is somehow unavailable, in
/// which case the caller falls back to the in-process UUID in posoco-ext-kimi.
extern "js" fn js_random_uuid() -> String =
  #| () => {
  #|   try {
  #|     const crypto = require("crypto");
  #|     if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
  #|   } catch {}
  #|   return "";
  #| }

///|
/// Resolve the stable Kimi device id for this working directory. The id lives
/// at `<cwd>/.cetas/kimi_device_id` and is created on first use: a fresh v4
/// UUID is minted via the host crypto module and persisted atomically so
/// subsequent runs (and the OAuth host's device list) see the same id. When
/// persistence fails the minted id is still returned so the OAuth flow can
/// proceed; only cross-run stability is lost.
fn resolve_kimi_device_id(cwd : String) -> String {
  let dir = cwd + "/.cetas"
  let path = dir + "/kimi_device_id"
  match read_file_sync(path) {
    Content(value) => {
      let trimmed = value.trim().to_owned()
      if trimmed.length() > 0 {
        trimmed
      } else {
        mint_and_persist_kimi_device_id(dir, path)
      }
    }
    Missing => mint_and_persist_kimi_device_id(dir, path)
    Failed(_) => mint_and_persist_kimi_device_id(dir, path)
  }
}

///|
/// Mint a new device id and best-effort persist it. Persistence failure is
/// non-fatal: the id is returned so the OAuth flow can proceed, only cross-run
/// stability is at risk. Mirrors kimi-code's `createKimiDeviceId` semantics.
fn mint_and_persist_kimi_device_id(dir : String, path : String) -> String {
  let host_uuid = js_random_uuid()
  // When host crypto is unavailable, defer to posoco-ext-kimi's process-local
  // UUID by returning "" (the extension mints one internally on empty input).
  let device_id = if host_uuid.length() > 0 { host_uuid } else { "" }
  if device_id.length() > 0 {
    bun_mkdir_sync(dir)
    let _ = bun_write_file_atomic(path, device_id)
  }
  device_id
}
