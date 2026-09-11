///|
/// Provider composition for cetas-js.
///
/// Cetas owns only generic sources (the settings JSON and credential files)
/// and registration of public provider-extension seams. Provider extensions
/// receive an opaque `ProviderConfigSource` and own defaults, endpoint/path
/// handling, protocol, model capabilities, and OAuth credential rebuilding.
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
  @credentials.FileProviderCredentialStore(
    @workspace.JsWorkspaceFs(),
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
fn JsAuthInteraction::JsAuthInteraction(
  observer_callback : JsCallback,
  request_callback : JsUiRequestCallback,
  cancel_check : JsCancelCheck,
) -> JsAuthInteraction {
  { observer_callback, request_callback, cancel_check, }
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
  match @workspace.read_file_result(@workspace.JsWorkspaceFs(), settings_path) {
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
      @workspace.JsWorkspaceFs(),
      home=runtime.config.home,
    ) {
    Ok(entries) => entries
    Err(_) => Map::from_array([])
  }
  // Fresh assembly starts from an empty issue list; per-provider build
  // failures accumulate here and surface as warnings, never as a fatal
  // composition error that would take down every healthy provider.
  runtime.catalog_issues = []
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
            let refresh_outcome = @cetas_core.refresh_provider_catalog(
              refresh_factory, snapshot,
            ) catch {
              err => {
                runtime.catalog_issues.push({
                  provider_id,
                  detail: err.to_string(),
                })
                None
              }
            }
            match refresh_outcome {
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
            @cetas_core.try_build_provider_catalog(
              factory,
              snapshot,
              cached_models=model_cache.get(provider_id),
            ) {
            Ok(build) =>
              match build {
                Some(catalog) => @llm.ProviderBuildResult::Ready(catalog)
                None => @llm.ProviderBuildResult::Unconfigured
              }
            Err(err) => {
              runtime.catalog_issues.push({
                provider_id,
                detail: err.to_string(),
              })
              @llm.ProviderBuildResult::Unconfigured
            }
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
    @workspace.JsWorkspaceFs(),
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
/// loudly (the same file is already validated for `providers`). The shared
/// event bus rides along so the router can publish model/token/cache status
/// ops alongside the other cetas extensions.
/// `extra_quota_sources` holds host-injected quota sources consulted before
/// the devkit registry; codex is push-shaped, so registering it there would
/// double-publish segments against CodexQuotaStatus.
async fn build_provider_router(
  runtime : CetasJsRuntime,
  store : @credentials.FileProviderCredentialStore,
  auth : JsAuthInteraction,
  observer : &@posoco.Observer,
  bus? : @devkit.EventBus? = None,
  extra_quota_sources? : Map[String, &@devkit.QuotaSource] = Map::from_array([]),
) -> @llm.RouterModelPort raise @posoco.CompositionError {
  let catalogs = cached_provider_catalogs(runtime)
  if catalogs.is_empty() {
    raise @posoco.CompositionError::EmptyPort("cetas-js.providers")
  }
  let selection = @cetas_core.read_active_model_selection(
    @workspace.JsWorkspaceFs(),
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
    bus~,
    provider_credential_store=Some(store as &@oauth.ProviderCredentialStore),
    auth_interaction=Some(auth as &@oauth.AuthInteraction),
    auth_prompt=Some(auth as &@oauth.AuthPromptInteraction),
    extra_quota_sources~,
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
  @cetas_core.provider_setup_json(
    catalogs,
    settings~,
    issues=runtime.catalog_issues,
  )
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
  http_method : String,
) -> String raise @posoco.CommandError {
  let interaction = JsAuthInteraction(
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
    http_method,
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
/// One `results` entry of the live-refresh summary, per the bridge contract:
/// `{"provider": id, "status": "refreshed"|"failed", "slots"?: N, "reason"?: "..."}`
/// (`slots` only on refresh, `reason` only when there is something to explain).
fn live_refresh_entry(
  provider_id : String,
  status : String,
  slots? : Int? = None,
  reason? : String? = None,
) -> Json {
  let fields : Array[(String, Json)] = [
    ("provider", Json::string(provider_id)),
    ("status", Json::string(status)),
  ]
  match slots {
    Some(count) => fields.push(("slots", Json::number(count.to_double())))
    None => ()
  }
  match reason {
    Some(detail) => fields.push(("reason", Json::string(detail)))
    None => ()
  }
  Json::object(Map::from_array(fields))
}

///|
fn live_refresh_summary(entries : Array[Json]) -> String {
  Json::object(Map::from_array([("results", Json::array(entries))])).stringify()
}

///|
/// Resolve the live-refresh inputs exactly like the forced path of
/// `collect_provider_catalogs`: settings load + validation, one credential
/// read per registered factory, and the settings-aware credential snapshot.
/// The device id and refreshable factory registry are resolved by the caller,
/// which needs them first to filter the selector against the refresh seams.
async fn prepare_live_refresh(
  runtime : CetasJsRuntime,
) -> (Array[&@llm.ProviderFactory], @cetas_core.ProviderCredentialSnapshot) raise @posoco.CompositionError {
  let settings = load_provider_settings(runtime)
  let factories = @cetas_core.all_provider_factories(
    @devkit.ExtContext::default(),
    settings,
  )
  @cetas_core.validate_provider_settings(settings, factories)
  let store = credential_store(runtime.config.home)
  let credentials = read_credential_snapshot(store, factories)
  let snapshot = @cetas_core.ProviderCredentialSnapshot::ProviderCredentialSnapshot(
    settings~,
    credentials~,
  )
  (factories, snapshot)
}

///|
/// Resolve the live-refresh selector against the refreshable factory
/// registry. An empty selector means every refreshable provider (`None`); an
/// explicit selector keeps only ids that HAVE a refresh seam. Providers
/// without one — e.g. custom openai-compatible endpoints from user settings,
/// which are static config refresh does not apply to — are skipped silently:
/// not refreshed, not warned, and absent from the summary. Only shape
/// problems (malformed JSON, non-array selector, malformed ids) raise, so
/// they ride the single `provider:""` entry like other genuine prep
/// failures. This pre-filter is what keeps the cetas-core resolution error
/// for unknown refresh ids from ever escaping the live path.
fn live_refresh_selector(
  raw : String,
  refreshables : Array[&@llm.RefreshableProviderFactory],
) -> Array[String]? raise @posoco.CompositionError {
  if raw.length() == 0 {
    return None
  }
  let refreshable_ids : Map[String, Unit] = Map::from_array([])
  for refresh_factory in refreshables {
    refreshable_ids[refresh_factory.provider_id()] = ()
  }
  let json = @json.parse(raw) catch {
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas.providers",
        detail="model refresh provider selector is not valid JSON",
      )
  }
  let values = match json {
    Json::Array(values) => values
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas.providers",
        detail="model refresh provider selector must be an array",
      )
  }
  let ids : Array[String] = []
  for value in values {
    let provider_id = match value {
      Json::String(value) if @cetas_core.valid_provider_id(value) => value
      _ =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="cetas.providers",
          detail="model refresh provider ids must be non-empty strings of letters, digits, '_', '-'",
        )
    }
    if refreshable_ids.contains(provider_id) && !ids.contains(provider_id) {
      ids.push(provider_id)
    }
  }
  Some(ids)
}

///|
/// Background-safe live model-catalog refresh (the cetas-acp
/// `refresh_model_lists` semantics brought to cetas-js). Per refreshable
/// provider, serially: refresh; success updates the process cache, persists
/// the disk cache, and hot-swaps the composed agent's router via
/// `replace_provider_slots` (the router preserves the active selection); a
/// failure appends a `catalog_issues` warning and KEEPS the current cache
/// entry — no eviction, deliberately diverging from the forced login-flow
/// path. Providers without a refresh seam (e.g. custom openai-compatible
/// endpoints from user settings) are skipped silently — refresh does not
/// apply to them. This entry never raises: every failure rides the summary
/// JSON.
async fn refresh_model_lists_live(
  runtime : CetasJsRuntime,
  provider_ids_json : String,
) -> String noraise {
  // The refreshable registry is resolved first so the selector can be
  // filtered against it BEFORE id resolution: ids without a refresh seam are
  // dropped silently instead of reaching the cetas-core resolution that
  // raises for them and collapses the whole refresh.
  let device_id = if runtime.config.home.length() > 0 {
    resolve_kimi_device_id(runtime.config.home)
  } else {
    ""
  }
  let refreshables = @cetas_core.refreshable_factories(
    @devkit.ExtContext::default(),
    device_id~,
  )
  let requested = live_refresh_selector(provider_ids_json, refreshables) catch {
    err =>
      return live_refresh_summary([
        live_refresh_entry("", "failed", reason=Some(err.to_string())),
      ])
  }
  let prepared = Ok(prepare_live_refresh(runtime)) catch {
    err => Err(err.to_string())
  }
  let (factories, snapshot) = match prepared {
    Ok(values) => values
    Err(reason) =>
      return live_refresh_summary([
        live_refresh_entry("", "failed", reason=Some(reason)),
      ])
  }
  refresh_model_lists_live_with(
    runtime, factories, refreshables, snapshot, requested,
  )
}

///|
/// Serial per-provider live refresh over an explicit factory list (the
/// seam tests inject fixture factories into). An empty selector refreshes
/// every refreshable provider; providers without a refresh seam (e.g.
/// custom openai-compatible endpoints from user settings) are skipped
/// silently — refresh does not apply to them, so they are neither warned
/// nor included in the summary.
async fn refresh_model_lists_live_with(
  runtime : CetasJsRuntime,
  factories : Array[&@llm.ProviderFactory],
  refreshables : Array[&@llm.RefreshableProviderFactory],
  snapshot : @cetas_core.ProviderCredentialSnapshot,
  requested : Array[String]?,
) -> String noraise {
  let refreshable_ids : Map[String, Unit] = Map::from_array([])
  for refresh_factory in refreshables {
    refreshable_ids[refresh_factory.provider_id()] = ()
  }
  let entries : Array[Json] = []
  for factory in factories {
    let provider_id = factory.provider_id()
    let selected = match requested {
      None => refreshable_ids.contains(provider_id)
      Some(ids) => ids.contains(provider_id)
    }
    if !selected {
      continue
    }
    let mut target : &@llm.RefreshableProviderFactory? = None
    for candidate in refreshables {
      if candidate.provider_id() == provider_id {
        target = Some(candidate)
      }
    }
    match target {
      // No refresh seam: skipped silently. Custom openai-compatible
      // providers are static config — refresh does not apply, so the id is
      // not warned and stays out of the summary.
      None => continue
      Some(refresh_factory) => {
        let outcome : Result[@llm.ProviderModelCatalog?, Error] = Ok(
          @cetas_core.refresh_provider_catalog(refresh_factory, snapshot),
        ) catch {
          err => Err(err)
        }
        match outcome {
          Err(err) => {
            // Failure keeps the stale slots standing: record the warning for
            // describe_setup, never evict, and ride the summary.
            runtime.catalog_issues.push({
              provider_id,
              detail: err.to_string(),
            })
            entries.push(
              live_refresh_entry(
                provider_id,
                "failed",
                reason=Some(err.to_string()),
              ),
            )
          }
          Ok(None) =>
            entries.push(
              live_refresh_entry(
                provider_id,
                "failed",
                reason=Some("not configured"),
              ),
            )
          Ok(Some(catalog)) => {
            runtime.catalog_cache[provider_id] = catalog
            persist_model_list_cache(runtime.config.home, provider_id, catalog)
            let mut swap_reason : String? = None
            match runtime.live_router {
              Some(router) => {
                let swapped : Result[Unit, Error] = try {
                  router.replace_provider_slots(provider_id, catalog.slots())
                  Ok(())
                } catch {
                  error => Err(error)
                }
                match swapped {
                  Ok(_) => ()
                  Err(error) =>
                    swap_reason = Some(
                      "refreshed, but the live router swap failed: " +
                      error.to_string(),
                    )
                }
              }
              None => ()
            }
            entries.push(
              live_refresh_entry(
                provider_id,
                "refreshed",
                slots=Some(catalog.slots().length()),
                reason=swap_reason,
              ),
            )
          }
        }
      }
    }
  }
  live_refresh_summary(entries)
}

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
  let fs = @workspace.JsWorkspaceFs()
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
/// stability is at risk.
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
