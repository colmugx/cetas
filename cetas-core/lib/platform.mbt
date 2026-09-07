///|
/// platform.mbt — process-level platform assembly shared by every cetas
/// host ("wherever you access cetas, it's the same cetas").
///
/// A `CetasPlatform` is built once per process: settings → factories →
/// credentials → model cache → catalogs → persisted selection, plus the
/// fs-session JSONL store and the refreshable provider seams. Every session
/// an agent host mints composes over the same platform; the lazy model-list
/// refresh swaps catalog entries in place for later sessions.
///
/// Host-specific concerns (ACP protocol bridges, fs delegation, debug taps,
/// MCP load mode) stay host-side; the platform carries only product facts.
/// Diagnostics are injected: `label~` prefixes every warn/error id (byte-
/// identical when a host keeps its own name) and `warn~` is the sink, so
/// this package still performs no IO of its own beyond the injected
/// WorkspaceFs.

///|
/// Process-level assembly shared by every session of one host process; built
/// once per process, the catalogs array is swapped in place by the lazy
/// refresh.
pub(all) struct CetasPlatform {
  home : String
  cwd : String
  fs : &@workspace.WorkspaceFs
  catalogs : Array[@llm.ProviderModelCatalog]
  default_slot_id : String
  /// Persisted reasoning effort restored onto every session's router.
  persisted_effort : String?
  /// Startup tool-approval posture, resolved by the host and stamped on
  /// every session; never persisted.
  permission_mode : @permission.PermissionMode
  credential_store : @credentials.FileProviderCredentialStore
  session_store : @fs_session.JsonlSessionStore
  refreshables : Array[&@llm.RefreshableProviderFactory]
  refresh_snapshot : ProviderCredentialSnapshot
  /// The host's process task group (nmem flusher, background monitors);
  /// `None` in tests without a group.
  mcp_group : @async.TaskGroup[Unit]?
}

///|
/// Swap one provider's catalog in the shared platform list so sessions minted
/// after a refresh compose from it; an empty list (tests) is left alone.
pub fn swap_platform_catalog(
  catalogs : Array[@llm.ProviderModelCatalog],
  provider_id : String,
  catalog : @llm.ProviderModelCatalog,
) -> Unit {
  if catalogs.is_empty() {
    return
  }
  for i in 0..<catalogs.length() {
    if catalogs[i].provider_id == provider_id {
      catalogs[i] = catalog
      return
    }
  }
  catalogs.push(catalog)
}

///|
/// Assemble the process platform once: settings → factories → credentials →
/// model cache → catalogs → persisted selection; fails loudly with no
/// provider configured. The persisted selection resolves here (drifted
/// slot/stale effort degrades with one warning); the model-list disk cache
/// seeds a restart's announcements without network. `permission_mode~` is
/// the host-resolved startup posture (e.g. from `CETAS_PERMISSION_MODE`).
pub async fn build_cetas_platform(
  home~ : String,
  cwd~ : String,
  fs : &@workspace.WorkspaceFs,
  permission_mode~ : @permission.PermissionMode,
  mcp_group? : @async.TaskGroup[Unit]? = None,
  label? : String = "cetas-acp",
  warn? : async (String) -> Unit noraise = fn(_ : String) { () },
) -> CetasPlatform raise @posoco.CompositionError {
  let settings = load_provider_settings(fs, home~, label~)
  let ext_ctx = @devkit.ExtContext::default()
  let factories = all_provider_factories(ext_ctx, settings)
  validate_provider_settings(settings, factories)
  let store = @credentials.FileProviderCredentialStore(
    fs,
    home + "/.cetas/credentials",
  )
  let snapshot = read_credential_snapshot(store, factories, settings~, label~)
  let model_cache = match read_model_list_cache(fs, home~) {
    Ok(entries) => entries
    Err(message) => {
      warn(
        label +
        ": model list cache unreadable (" +
        message +
        "); announcing static catalogs until the first refresh lands\n",
      )
      Map::from_array([])
    }
  }
  let catalogs : Array[@llm.ProviderModelCatalog] = []
  for factory in factories {
    let provider_id = factory.provider_id()
    let cached = model_cache.get(provider_id)
    match try_build_provider_catalog(factory, snapshot, cached_models=cached) {
      Ok(Some(catalog)) => catalogs.push(catalog)
      Ok(None) => ()
      Err(err) =>
        // One misconfigured provider must not take down the whole host.
        warn(
          label +
          ": provider " +
          provider_id +
          " skipped: " +
          err.to_string() +
          "\n",
        )
    }
  }
  if catalogs.is_empty() {
    raise @posoco.CompositionError::EmptyPort(
      label +
      ".providers: no configured model provider — configure one in ~/.cetas/settings.json or log in via cetas first",
    )
  }
  // No OAuth surface in a headless/stdio process; token refresh works for
  // on-disk credentials.
  let selection = read_active_model_selection(fs, home~)
  let default_slot_id = resolve_default_slot_id(catalogs, selection)
  match selection {
    Some({ slot, .. }) =>
      if default_slot_id == "" {
        warn(
          label +
          ": persisted model slot '" +
          slot +
          "' is no longer configured; using the first catalog slot (stale entry kept in ~/.cetas/settings.json)\n",
        )
      }
    None => ()
  }
  let persisted_effort = match selection {
    Some({ effort: Some(effort), .. }) => Some(effort)
    _ => None
  }
  let session_store = @fs_session.JsonlSessionStore(home + "/.cetas/sessions")
  // `device_id` stays empty: no host crypto surface in stdio; providers mint a local id.
  let refreshables = refreshable_factories(ext_ctx)
  {
    home,
    cwd,
    fs,
    catalogs,
    default_slot_id,
    persisted_effort,
    permission_mode,
    credential_store: store,
    session_store,
    refreshables,
    refresh_snapshot: snapshot,
    mcp_group,
  }
}

///|
/// Read `~/.cetas/settings.json` and return its `providers` object. Missing
/// file means no settings; malformed content fails composition loudly.
pub async fn load_provider_settings(
  fs : &@workspace.WorkspaceFs,
  home~ : String,
  label? : String = "cetas-acp",
) -> Map[String, Json] raise @posoco.CompositionError {
  let manifest_id = label + ".providers"
  match @workspace.read_file_result(fs, home + "/.cetas/settings.json") {
    Missing => Map::from_array([])
    Failed(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id~,
        detail=".cetas/settings.json read failed: " + message,
      )
    Content(text) => {
      let json = @json.parse(text) catch {
        _ =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id~,
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
                manifest_id~,
                detail="settings.providers must be an object",
              )
          }
        _ =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id~,
            detail=".cetas/settings.json must be an object",
          )
      }
    }
  }
}

///|
/// Read every provider's credential once; missing/unconfigured providers map to no entry.
pub async fn read_credential_snapshot(
  store : @credentials.FileProviderCredentialStore,
  factories : Array[&@llm.ProviderFactory],
  settings~ : Map[String, Json],
  label? : String = "cetas-acp",
) -> ProviderCredentialSnapshot raise @posoco.CompositionError {
  let credentials : Map[String, @oauth.ProviderCredential] = Map::from_array([])
  for factory in factories {
    let provider_id = factory.provider_id()
    let credential = store.read(provider_id) catch {
      err =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id=label + ".credentials",
          detail=oauth_error_text(err),
        )
    }
    match credential {
      Some(value) => credentials[provider_id] = value
      None => ()
    }
  }
  ProviderCredentialSnapshot::ProviderCredentialSnapshot(
    settings~,
    credentials~,
  )
}

// ------------------------------------------------------- session id minting

///|
/// Process-global (not per host) so two hosts in one process cannot mint the same id.
priv struct DurableIdState {
  mut last_ms : Int64
  mut last_seq : Int
}

///|
let durable_id_state : DurableIdState = { last_ms: 0L, last_seq: -1, }

///|
/// `cetas-<epoch-ms>`, with a `-<seq>` suffix once mints outpace the clock;
/// the sequence only grows, so ids stay fresh across a clock regression.
/// Shape passes ext-fs-session's `validate_session_id` (safe JSONL stem).
pub fn mint_session_id() -> String {
  let now = @async.now()
  let state = durable_id_state
  if now > state.last_ms {
    state.last_ms = now
    state.last_seq = 0
    "cetas-\{now}"
  } else {
    state.last_seq += 1
    "cetas-\{now}-\{state.last_seq}"
  }
}

// -------------------------------------------------------------- host sidecar

///|
/// Empty strings and an empty roster mean "unknown" — a missing or corrupt
/// sidecar degrades to these defaults instead of failing the restore.
pub(all) struct SessionSidecar {
  cwd : String
  model : String
  effort : String?
  mcp_servers : Array[String]
}

///|
/// Beside the JSONL history, but host-owned (workspace fs, never the session store).
pub fn sidecar_path(home : String, session_id : String) -> String {
  home + "/.cetas/sessions/" + session_id + ".host.json"
}

///|
fn sidecar_string_field(fields : Map[String, Json], key : String) -> String {
  match fields.get(key) {
    Some(Json::String(value)) => value
    _ => ""
  }
}

///|
fn sidecar_effort_field(fields : Map[String, Json]) -> String? {
  match fields.get("effort") {
    Some(Json::String(value)) => Some(value)
    _ => None
  }
}

///|
fn sidecar_mcp_names(fields : Map[String, Json]) -> Array[String] {
  let names : Array[String] = []
  match fields.get("mcp_servers") {
    Some(Json::Array(items)) =>
      for item in items {
        match item {
          Json::String(name) => names.push(name)
          _ => ()
        }
      }
    _ => ()
  }
  names
}

///|
/// Missing, unreadable, or malformed content is `None`, never an error; a
/// corrupt file warns once so the data loss stays observable.
pub async fn read_session_sidecar(
  fs : &@workspace.WorkspaceFs,
  home~ : String,
  session_id~ : String,
  label? : String = "cetas-acp",
  warn? : async (String) -> Unit noraise = fn(_ : String) { () },
) -> SessionSidecar? noraise {
  let path = sidecar_path(home, session_id)
  match @workspace.read_file_result(fs, path) {
    Missing => None
    Failed(message) => {
      warn(
        label +
        ": session sidecar unreadable (" +
        path +
        "): " +
        message +
        "; restoring defaults\n",
      )
      None
    }
    Content(text) => {
      let parsed : Result[Json, Error] = Ok(@json.parse(text)) catch {
        error => Err(error)
      }
      match parsed {
        Ok(Json::Object(fields)) =>
          Some({
            cwd: sidecar_string_field(fields, "cwd"),
            model: sidecar_string_field(fields, "model"),
            effort: sidecar_effort_field(fields),
            mcp_servers: sidecar_mcp_names(fields),
          })
        _ => {
          warn(
            label +
            ": session sidecar is not a JSON object (" +
            path +
            "); restoring defaults\n",
          )
          None
        }
      }
    }
  }
}

///|
/// Refresh one session's sidecar from its live facts: model/effort come from
/// the caller's router view; cwd and the MCP roster survive from the existing
/// sidecar (the roster cannot be recomputed later); `fresh_mcp_names~` seeds
/// a fresh one. Runs under `persist_lock~` when the host serializes its
/// persistence cycles; atomic and best-effort.
pub async fn update_session_sidecar(
  fs : &@workspace.WorkspaceFs,
  home~ : String,
  session_id~ : String,
  live_cwd~ : String,
  model~ : String,
  effort~ : String?,
  fresh_mcp_names~ : Array[String],
  persist_lock? : @async.Mutex? = None,
  label? : String = "cetas-acp",
  warn? : async (String) -> Unit noraise = fn(_ : String) { () },
) -> Unit noraise {
  match persist_lock {
    Some(lock) =>
      lock.acquire() catch {
        _ => {
          warn(
            label +
            ": session sidecar write skipped (session=" +
            session_id +
            ")\n",
          )
          return
        }
      }
    None => ()
  }
  // The body below has no early return, so the lock releases once at the end.
  let existing = read_session_sidecar(fs, home~, session_id~, label~, warn~)
  let cwd = match existing {
    Some({ cwd, .. }) => if cwd.length() > 0 { cwd } else { live_cwd }
    None => live_cwd
  }
  let mcp_servers = match existing {
    Some({ mcp_servers, .. }) =>
      if mcp_servers.is_empty() {
        fresh_mcp_names
      } else {
        mcp_servers
      }
    None => fresh_mcp_names
  }
  let effort_json = match effort {
    Some(value) => Json::string(value)
    None => Json::null()
  }
  let json = Json::object(
    Map::from_array([
      ("cwd", Json::string(cwd)),
      ("model", Json::string(model)),
      ("effort", effort_json),
      ("mcp_servers", Json::array(mcp_servers.map(name => Json::string(name)))),
    ]),
  )
  fs.write_file_atomic(
    sidecar_path(home, session_id),
    json.stringify(indent=2) + "\n",
  ) catch {
    _ =>
      warn(
        label + ": session sidecar write failed (session=" + session_id + ")\n",
      )
  }
  match persist_lock {
    Some(lock) => lock.release()
    None => ()
  }
}
