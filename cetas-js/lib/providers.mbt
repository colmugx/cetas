///|
/// Provider composition for cetas-js.
///
/// Cetas owns only generic sources (the settings JSON and credential files)
/// and registration of public provider-extension seams. Provider extensions
/// receive an opaque `ProviderConfigSource` and own defaults, endpoint/path
/// handling, protocol, model capabilities, and OAuth credential rebuilding.
/// There is deliberately no provider-id switch or legacy environment fallback
/// in this package.
///
/// All filesystem access goes through `posoco-ext-workspace` (`WorkspaceFs`);
/// credential persistence is delegated to `posoco-ext-credentials`
/// (`FileProviderCredentialStore`).

///|
/// The host's credential store: one tagged record per provider below the
/// Cetas home directory (`~/.cetas/credentials`), persisted through the
/// workspace fs boundary.
///
/// Credentials live under the user's HOME, never the project working tree, so
/// they cannot be committed to a repository or shipped in an artifact. The
/// root is injected by the host (`CetasJsConfig.home`, resolved to
/// `os.homedir()` by both production entry points).
fn credential_store(home : String) -> @credentials.FileProviderCredentialStore {
  @credentials.FileProviderCredentialStore::new(
    @workspace.JsWorkspaceFs::new(),
    home + "/.cetas/credentials",
  )
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
async fn load_provider_settings(
  runtime : CetasJsRuntime,
) -> Map[String, Json] raise @posoco.CompositionError {
  let settings_path = runtime.config.home + "/.cetas/settings.json"
  match
    @workspace.read_file_result(@workspace.JsWorkspaceFs::new(), settings_path) {
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
///
/// The caller supplies the settings-aware factory list (static providers plus
/// one openai-compatible instance per custom settings id) so custom providers'
/// credentials are read identically to static ones.
async fn read_credential_snapshot(
  store : @credentials.FileProviderCredentialStore,
  factories : Array[&@llm.ProviderFactory],
) -> Map[String, @oauth.ProviderCredential] raise @posoco.CompositionError {
  let credentials : Map[String, @oauth.ProviderCredential] = Map::from_array([])
  for factory in factories {
    let provider_id = factory.provider_id()
    let credential = store.read(provider_id) catch {
      err =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="cetas-js.credentials",
          detail=@cetas_core.oauth_error_text(err),
        )
    }
    match credential {
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
/// The disk model cache (`~/.cetas/model_lists.json`, cetas-core) seeds
/// uncached provider builds so a cold process announces the previously
/// discovered list without a network request, and a successful forced
/// refresh writes its projection back so the next process starts warm. The
/// cache is best-effort: read or write failures degrade silently — the
/// process cache and the explicit refresh remain the sources of truth.
///
/// Factory wiring and validation live in cetas-core; this host owns only the
/// process-lifetime cache.
async fn collect_provider_catalogs(
  runtime : CetasJsRuntime,
  requested : Array[String]?,
  force : Bool,
) -> Array[@llm.ProviderModelCatalog] raise @posoco.CompositionError {
  let ctx = @devkit.ExtContext::default()
  let settings = load_provider_settings(runtime)
  let factories = @cetas_core.all_provider_factories(ctx, settings)
  @cetas_core.validate_provider_settings(settings, factories)
  let store = credential_store(runtime.config.home)
  let credentials = read_credential_snapshot(store, factories)
  let snapshot = @cetas_core.ProviderCredentialSnapshot::ProviderCredentialSnapshot(
    settings~,
    credentials~,
  )
  let device_id = if runtime.config.home.length() > 0 {
    resolve_kimi_device_id(runtime.config.home)
  } else {
    ""
  }
  let model_cache = match
    @cetas_core.read_model_list_cache(
      @workspace.JsWorkspaceFs::new(),
      home=runtime.config.home,
    ) {
    Ok(entries) => entries
    Err(_) => Map::from_array([])
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
              Some(catalog) => {
                persist_model_list_cache(
                  runtime.config.home,
                  provider_id,
                  catalog,
                )
                refreshed = Some(@llm.ProviderBuildResult::Ready(catalog))
              }
              None => refreshed = Some(@llm.ProviderBuildResult::Unconfigured)
            }
          }
        }
      }
      let result = match refreshed {
        Some(value) => value
        None =>
          match
            @cetas_core.build_provider_catalog(
              factory,
              snapshot,
              cached_models=model_cache.get(provider_id),
            ) {
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
/// Best-effort write of one refreshed catalog's model records to the disk
/// cache. Failures are silent by design: the cache only accelerates the next
/// cold start, and the next refresh will rewrite it anyway.
async fn persist_model_list_cache(
  home : String,
  provider_id : String,
  catalog : @llm.ProviderModelCatalog,
) -> Unit noraise {
  @cetas_core.write_model_list_cache(
    @workspace.JsWorkspaceFs::new(),
    home~,
    provider_id,
    @cetas_core.catalog_model_records(catalog),
  ) catch {
    _ => ()
  }
}

///|
/// Use the process cache without forcing a network/model discovery refresh.
async fn cached_provider_catalogs(
  runtime : CetasJsRuntime,
) -> Array[@llm.ProviderModelCatalog] raise @posoco.CompositionError {
  collect_provider_catalogs(runtime, None, false)
}

///|
/// One observer `Custom` warning on the shared bridge channel; used when a
/// persisted selection cannot be applied (slot drifted, effort no longer
/// advertised) — restore problems degrade to defaults instead of blocking
/// startup.
fn active_model_warning(
  observer : &@posoco.Observer,
  label : String,
  message : String,
) -> Unit {
  let event : @posoco.TurnEvent = Custom(
    source="cetas-js.bridge",
    label~,
    data=Json::object(Map::from_array([("message", Json::string(message))])),
  )
  observer.on_event(event)
}

///|
/// Build the provider router with the persisted active-model selection
/// restored: `~/.cetas/settings.json`'s flat `model`/`reasoning_effort` keys
/// pick the default slot and effort instead of always resetting to the first
/// catalog slot. A drifted slot or stale effort degrades to the router default
/// with one observer warning; malformed settings still fail composition
/// loudly (the same file is already validated for `providers`).
async fn build_provider_router(
  runtime : CetasJsRuntime,
  store : @credentials.FileProviderCredentialStore,
  auth : JsAuthInteraction,
  observer : &@posoco.Observer,
) -> @llm.RouterModelPort raise @posoco.CompositionError {
  let catalogs = cached_provider_catalogs(runtime)
  if catalogs.is_empty() {
    raise @posoco.CompositionError::EmptyPort("cetas-js.providers")
  }
  let selection = @cetas_core.read_active_model_selection(
    @workspace.JsWorkspaceFs::new(),
    home=runtime.config.home,
  )
  let default_slot_id = @cetas_core.resolve_default_slot_id(catalogs, selection)
  match selection {
    Some({ slot, .. }) =>
      if default_slot_id == "" {
        active_model_warning(
          observer,
          "active_model_restore_warning",
          "Persisted model slot '" +
          slot +
          "' is no longer configured; falling back to the first catalog slot. The stale entry stays in ~/.cetas/settings.json until the next selection overwrites it.",
        )
      }
    None => ()
  }
  let router = @llm.RouterModelPort::from_catalogs(
    catalogs,
    default_slot_id~,
    provider_credential_store=Some(store as &@oauth.ProviderCredentialStore),
    auth_interaction=Some(auth as &@oauth.AuthInteraction),
    auth_prompt=Some(auth as &@oauth.AuthPromptInteraction),
  )
  match selection {
    Some({ effort: Some(effort), .. }) =>
      if default_slot_id != "" {
        router.select_effort(default_slot_id, effort) catch {
          _ =>
            active_model_warning(
              observer,
              "active_model_restore_warning",
              "Persisted reasoning effort '" +
              effort +
              "' is not advertised by model slot '" +
              default_slot_id +
              "'; using the slot's default effort.",
            )
        }
      }
    _ => ()
  }
  router
}

///|
/// Provider capability discovery before Agent composition. The setup JSON
/// assembly is provider-neutral and lives in cetas-core; this host only feeds
/// it the cached catalogs.
async fn provider_setup_json(
  runtime : CetasJsRuntime,
) -> String raise @posoco.CompositionError {
  let catalogs = cached_provider_catalogs(runtime)
  let settings = load_provider_settings(runtime)
  @cetas_core.provider_setup_json(catalogs, settings~)
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
/// credential outcome; this host persists it through the credential store and
/// invalidates its catalog cache so the next composition sees the new
/// credential.
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
  let store = credential_store(runtime.config.home)
  let device_id = if runtime.config.home.length() > 0 {
    resolve_kimi_device_id(runtime.config.home)
  } else {
    ""
  }
  let settings = load_provider_settings(runtime) catch {
    err => raise @posoco.CommandError::ExecutionFailed(err.to_string())
  }
  let outcome = @cetas_core.login_provider(
    provider_id,
    method,
    settings~,
    device_id~,
    interaction as &@oauth.AuthInteraction,
    interaction as &@oauth.AuthPromptInteraction,
  )
  store.write(outcome.provider_id, outcome.credential) catch {
    err =>
      raise @posoco.CommandError::ExecutionFailed(
        outcome.login_method +
        " credential persistence failed for " +
        provider_id +
        ": " +
        @cetas_core.oauth_error_text(err),
      )
  }
  runtime.catalog_cache.remove(provider_id)
  @cetas_core.login_outcome_json(outcome)
}

///|
/// Mint a v4 UUID via the host runtime's crypto module (Node / Bun both ship
/// `crypto.randomUUID`). Returns "" only if crypto is somehow unavailable, in
/// which case the caller falls back to the in-process UUID in posoco-ext-kimi.
extern "js" fn js_random_uuid() -> String =
  #| () => {
  #|   try {
  #|     const crypto = require("node:crypto");
  #|     if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
  #|   } catch {}
  #|   return "";
  #| }

///|
/// Resolve the stable Kimi device id for this user. The id lives at
/// `<home>/.cetas/kimi_device_id` and is created on first use: a fresh v4
/// UUID is minted via the host crypto module and persisted atomically so
/// subsequent runs (and the OAuth host's device list) see the same id. When
/// persistence fails the minted id is still returned so the OAuth flow can
/// proceed; only cross-run stability is lost.
///
/// The device id follows the user's HOME (not the project working tree) so it
/// is stable across projects and never leaks into a repository.
async fn resolve_kimi_device_id(home : String) -> String noraise {
  let fs = @workspace.JsWorkspaceFs::new()
  let dir = home + "/.cetas"
  let path = dir + "/kimi_device_id"
  match @workspace.read_file_result(fs, path) {
    Content(value) => {
      let trimmed = value.trim().to_owned()
      if trimmed.length() > 0 {
        trimmed
      } else {
        mint_and_persist_kimi_device_id(fs, dir, path)
      }
    }
    _ => mint_and_persist_kimi_device_id(fs, dir, path)
  }
}

///|
/// Mint a new device id and best-effort persist it. Persistence failure is
/// non-fatal: the id is returned so the OAuth flow can proceed, only cross-run
/// stability is at risk. Mirrors kimi-code's `createKimiDeviceId` semantics.
async fn mint_and_persist_kimi_device_id(
  fs : &@workspace.WorkspaceFs,
  dir : String,
  path : String,
) -> String noraise {
  let host_uuid = js_random_uuid()
  // When host crypto is unavailable, defer to posoco-ext-kimi's process-local
  // UUID by returning "" (the extension mints one internally on empty input).
  let device_id = if host_uuid.length() > 0 { host_uuid } else { "" }
  if device_id.length() > 0 {
    fs.mkdir(dir, recursive=true) catch {
      _ => ()
    }
    fs.write_file_atomic(path, device_id) catch {
      _ => ()
    }
  }
  device_id
}
