///|
/// magpie_manager.mbt — host-owned Magpie integration boundary for the
/// console runtime.
///
/// Cetas composes exactly one ModelPort per Agent (Posoco cardinality). The
/// model manager is chosen from `~/.cetas/settings.json` (`model_manager`:
/// the default `"providers"` keeps the ext-llm router, `"magpie"` composes
/// the Magpie runtime instead); switching managers rebuilds the session
/// through the recompose path. Magpie-specific surfaces (gateway
/// intelligence, routing groups, effort ladders) stay behind this file and
/// behind the runtime's own `magpie_*` commands — ext-llm never sees them.
/// The merge/selection persistence semantics are shared with cetas-js through
/// `cetas-core`'s active-model helpers; this file mirrors
/// `cetas-js/lib/magpie_manager.mbt` and the two must move together.

///|
/// Provider id used for the Magpie gateway credential inside the shared
/// credential store. Loopback gateways need no credential.
const MAGPIE_PROVIDER_ID : String = "magpie"

///|
/// Magpie catalog entries surface in the existing model picker under this
/// provider group, keeping them visibly separate from ordinary providers.
const MAGPIE_PICKER_PROVIDER : String = "magpie"

///|
/// Host-side Magpie settings resolved at composition time. `runtime_json` is
/// what goes into `MagpieRuntime::activate`; `config`/`transport` are kept so
/// subagent composition can build child managers with independent selection
/// state instead of sharing the parent's.
pub struct MagpieBinding {
  runtime : @magpie.MagpieRuntime
  config : @magpie.MagpieConfig
  transport : &@magpie.MagpieTransport
}

///|
/// One composed Agent owns exactly one model manager. Providers keeps the
/// ext-llm router; Magpie binds the Magpie runtime.
pub enum ModelManagerFace {
  Providers(@ext_llm.RouterModelPort)
  Magpie(MagpieBinding)
}

///|
/// The extension contributing the single ModelPort, joining the composition
/// at the router's product position.
fn ModelManagerFace::manager_extension(
  self : ModelManagerFace,
) -> &@posoco.Extension {
  match self {
    Providers(router) => router as &@posoco.Extension
    Magpie(binding) => binding.runtime as &@posoco.Extension
  }
}

///|
/// The single ModelPort of the active manager (MCP runtime wiring).
fn ModelManagerFace::manager_port(
  self : ModelManagerFace,
) -> &@posoco.ModelPort {
  match self {
    Providers(router) => router as &@posoco.ModelPort
    Magpie(binding) => binding.runtime.model_port() as &@posoco.ModelPort
  }
}

///|
/// Control contract shared by ext-llm and ext-magpie. Concrete dispatch is
/// limited to this adapter; callers see only ModelManagerControl.
fn ModelManagerFace::manager_control(
  self : ModelManagerFace,
) -> &@modelmgmt.ModelManagerControl {
  match self {
    Providers(router) => router as &@modelmgmt.ModelManagerControl
    Magpie(binding) =>
      binding.runtime.manager() as &@modelmgmt.ModelManagerControl
  }
}

///|
/// Wire identity of the active manager, for host panels and picker headers.
fn manager_id(manager : ModelManagerFace) -> String {
  manager.manager_control().manager_id()
}

///|
fn ModelManagerFace::manager_active_model_id(self : ModelManagerFace) -> String {
  self.manager_control().active_selection().model_id
}

///|
fn ModelManagerFace::manager_active_effort(self : ModelManagerFace) -> String? {
  self.manager_control().active_selection().effort
}

///|
/// Each adapter fulfills the same status contract. The ext-llm manager owns
/// the "model" segment (model name and effort), while Cetas separately
/// publishes its full active slot ID for provider disambiguation. The Magpie
/// adapter owns its own "model" segment. Both publish a manager label through
/// the same host-minted capability (owner `cetas.model_manager`). No UI needs
/// to know either.
fn ModelManagerFace::manager_publish_status(
  self : ModelManagerFace,
  events : @posoco.Events?,
) -> Unit {
  let control = self.manager_control()
  let selection = control.active_selection()
  let label = match self {
    Providers(_) => "Posoco"
    Magpie(_) => "Magpie"
  }
  publish_manager_status(events, segment="manager", priority=21, value=label)
  match self {
    Providers(router) =>
      // A model name alone cannot distinguish an official provider from an
      // aggregator serving the same model. Keep the router's exact slot ID;
      // ext-llm remains the authority for the reasoning-effort suffix.
      publish_manager_status(
        events,
        segment="model_slot",
        priority=19,
        value=router.active_slot_id(),
      )
    Magpie(_) => {
      let effort = match selection.effort {
        Some(value) => value
        None => {
          let mut selected = "default"
          for info in control.list_models() {
            if info.model_id == selection.model_id {
              selected = info.default_effort.unwrap_or("default")
              break
            }
          }
          selected
        }
      }
      publish_manager_status(
        events,
        segment="model",
        priority=20,
        value=selection.model_id + ":" + effort,
      )
    }
  }
}

///|
/// Publish one manager segment as a typed `StatusChanged(Register)` op.
/// Fire-and-forget: a closed channel only means the session is retiring.
fn publish_manager_status(
  events : @posoco.Events?,
  segment~ : String,
  priority~ : Int32,
  value~ : String,
) -> Unit {
  match events {
    Some(events) =>
      ignore(
        events.publish(
          @kit_events.StatusChanged(
            @kit_events.Register(
              segment~,
              label=None,
              priority~,
              value=Some(value),
              color=None,
            ),
          ),
        ),
      )
    None => ()
  }
}

///|
/// Provider-neutral metadata for one selectable model, as a manager's catalog
/// reports it.
priv struct MagpieHostSettings {
  base_url : String?
  enabled : Bool
  gateway_key : String?
  model : String?
  effort : String?
}

///|
/// Read the host-side Magpie settings. The gateway key comes only from the
/// shared credential store under HOME; a `gateway_key` field inside
/// settings.json is ignored and reported, never used — credentials do not
/// belong in editable configuration files. Malformed settings files fail
/// loudly, matching how provider settings treat the same file.
async fn read_magpie_host_settings(
  fs : &@workspace.WorkspaceFs,
  home~ : String,
  cred_store~ : @credentials.FileProviderCredentialStore,
  warn~ : async (String) -> Unit noraise,
) -> MagpieHostSettings? raise @posoco.CompositionError {
  let text = match
    @workspace.read_file_result(fs, home + "/.cetas/settings.json") {
    Missing => return None
    Failed(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-console.magpie",
        detail=".cetas/settings.json read failed: " + message,
      )
    Content(text) => text
  }
  let json = @json.parse(text) catch {
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-console.magpie",
        detail=".cetas/settings.json is not valid JSON",
      )
  }
  guard json is Json::Object(fields) else {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="cetas-console.magpie",
      detail=".cetas/settings.json must contain a JSON object",
    )
  }
  match fields.get("model_manager") {
    Some(Json::String("magpie")) => ()
    _ => return None
  }
  let mut base_url : String? = None
  let mut enabled = true
  match fields.get("magpie") {
    Some(Json::Object(magpie)) => {
      match magpie.get("base_url") {
        Some(Json::String(url)) => base_url = Some(url)
        Some(Json::Null) | None => ()
        Some(_) =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="cetas-console.magpie",
            detail="settings.magpie.base_url must be a string",
          )
      }
      match magpie.get("enabled") {
        Some(Json::True) => enabled = true
        Some(Json::False) => enabled = false
        Some(Json::Null) | None => ()
        Some(_) =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="cetas-console.magpie",
            detail="settings.magpie.enabled must be a boolean",
          )
      }
      if magpie.get("gateway_key") is Some(_) {
        warn(
          "settings.json magpie.gateway_key is ignored; store the gateway credential with the shared credential store (provider id '" +
          MAGPIE_PROVIDER_ID +
          "') instead of editable configuration.",
        )
      }
    }
    Some(Json::Null) | None => ()
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-console.magpie",
        detail="settings.magpie must be an object",
      )
  }
  let mut model : String? = None
  let mut effort : String? = None
  match fields.get("model") {
    Some(Json::String(value)) => model = Some(value)
    Some(Json::Null) | None => ()
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-console.magpie",
        detail="settings.model must be a string",
      )
  }
  match fields.get("reasoning_effort") {
    Some(Json::String(value)) => effort = Some(value)
    Some(Json::Null) | None => ()
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-console.magpie",
        detail="settings.reasoning_effort must be a string",
      )
  }
  let stored : @oauth.ProviderCredential? = cred_store.read(MAGPIE_PROVIDER_ID) catch {
    _ => None
  }
  let gateway_key : String? = match stored {
    Some(@oauth.ProviderCredential::ApiKey(key)) => Some(key.secret)
    Some(@oauth.ProviderCredential::OAuth(credential)) =>
      Some(credential.access_token)
    _ => None
  }
  Some({ base_url, enabled, gateway_key, model, effort, })
}

///|
/// Activate the Magpie runtime from host settings. The settings JSON feeds
/// `MagpieRuntime::activate`, which applies gateway defaults and its own
/// pending-selection semantics; invalid values degrade to a disabled runtime
/// with a recorded reason instead of failing composition.
fn bind_magpie_manager(
  settings : MagpieHostSettings,
  transport~ : &@magpie.MagpieTransport? = None,
) -> MagpieBinding raise @posoco.CompositionError {
  let pairs : Array[(String, Json)] = [
    ("enabled", Json::boolean(settings.enabled)),
  ]
  match settings.base_url {
    Some(url) => pairs.push(("base_url", Json::string(url)))
    None => ()
  }
  match settings.gateway_key {
    Some(key) => pairs.push(("gateway_key", Json::string(key)))
    None => ()
  }
  match settings.model {
    Some(model) => pairs.push(("model", Json::string(model)))
    None => ()
  }
  match settings.effort {
    Some(effort) => pairs.push(("effort", Json::string(effort)))
    None => ()
  }
  let transport : &@magpie.MagpieTransport = match transport {
    Some(transport) => transport
    None => @magpie.magpie_http_transport()
  }
  let runtime = @magpie.MagpieRuntime::activate(
    settings=Some(Json::object(Map::from_array(pairs))),
    transport~,
  )
  // Child managers (subagents) rebuild from the same endpoint material with
  // their own selection state; a degraded activation's defaults are safe to
  // reuse.
  let config_error = fn(message : String) -> @posoco.CompositionError {
    @posoco.CompositionError::ManifestSchemaError(
      manifest_id="cetas-console.magpie",
      detail=message,
    )
  }
  let config : @magpie.MagpieConfig = match settings.base_url {
    Some(url) =>
      @magpie.MagpieConfig::MagpieConfig(
        base_url=url,
        credential=settings.gateway_key,
        enabled=settings.enabled,
        selected_model=settings.model,
        selected_effort=settings.effort,
      ) catch {
        error =>
          raise config_error("magpie config rejected: " + error.to_string())
      }
    None =>
      @magpie.MagpieConfig::MagpieConfig(
        credential=settings.gateway_key,
        enabled=settings.enabled,
        selected_model=settings.model,
        selected_effort=settings.effort,
      ) catch {
        error =>
          raise config_error("magpie config rejected: " + error.to_string())
      }
  }
  { runtime, config, transport, }
}

///|
/// Resolve the console session's Magpie binding from `~/.cetas/settings.json`.
/// `Some(binding)` when `model_manager` is `"magpie"`; `None` composes the
/// providers router. Call before `build_cetas_session` so the foreign manager
/// can take the router's product position.
async fn resolve_console_magpie_binding(
  fs : &@workspace.WorkspaceFs,
  home~ : String,
  warn~ : async (String) -> Unit noraise,
) -> MagpieBinding? raise @posoco.CompositionError {
  match
    read_magpie_host_settings(
      fs,
      home~,
      cred_store=credential_store(fs, home),
      warn~,
    ) {
    Some(settings) => Some(bind_magpie_manager(settings))
    None => None
  }
}

///|
/// Magpie catalog entries in the shared model-picker slot shape. The Magpie
/// variant maps the manager catalog into the router slot fields one-for-one;
/// the provider field stays the fixed "magpie" group so the picker keeps
/// Magpie entries visibly separate from ordinary providers. Effort values
/// pass through verbatim — Magpie ladders are never normalized.
fn ModelManagerFace::manager_catalog_slots_json(
  self : ModelManagerFace,
) -> Array[Json] {
  match self {
    Providers(_) => []
    Magpie(binding) => {
      let manager = binding.runtime.manager()
      let control = manager as &@modelmgmt.ModelManagerControl
      let selection = control.active_selection()
      control
      .list_models()
      .map(fn(model : @modelmgmt.ManagerModelInfo) {
        let efforts : Array[Json] = model.efforts.map(fn(effort) {
          Json::string(effort)
        })
        Json::object(
          Map::from_array([
            ("id", Json::string(model.model_id)),
            ("label", Json::string(model.label)),
            ("provider", Json::string(MAGPIE_PICKER_PROVIDER)),
            ("model", Json::string(model.model_id)),
            ("active", Json::boolean(model.model_id == selection.model_id)),
            ("efforts", Json::array(efforts)),
            (
              "default_effort",
              match model.default_effort {
                Some(effort) => Json::string(effort)
                None => Json::null()
              },
            ),
            (
              "group",
              match manager.catalog_entry(model.model_id) {
                Some(entry) =>
                  if entry.meta.is_routing_group {
                    Json::string("Routing Groups")
                  } else {
                    Json::string(@devkit.sanitize_label(entry.meta.provider_id))
                  }
                None => Json::null()
              },
            ),
            // An unknown capacity stays null: a fabricated default would
            // mislead the picker worse than an absent column.
            (
              "context_window",
              match model.context_window {
                Some(window) => Json::number(window.to_double())
                None => Json::null()
              },
            ),
            ("context_window_source", Json::string("catalog")),
            ("context_window_stale", Json::boolean(false)),
          ]),
        )
      })
    }
  }
}

///|
/// Rebuild a fresh model-manager extension for one subagent: providers get a
/// router over the parent's slots (per-child selection), Magpie gets a child
/// manager bound to the same endpoint material with its own selection state.
fn ModelManagerFace::manager_subagent_extension(
  self : ModelManagerFace,
  spec_slot~ : String,
  spec_effort~ : String?,
) -> &@posoco.Extension raise @subagent.ComposerError {
  match self {
    Providers(router) => {
      let child = @ext_llm.RouterModelPort(
        slots=router.list_slots(),
        model_metadata=router.model_metadata,
        default_slot_id=spec_slot,
      ) catch {
        error =>
          raise @subagent.ComposerError::Failed(
            "child model selection failed: " + error.to_string(),
          )
      }
      match spec_effort {
        Some(effort) =>
          child.select_effort(spec_slot, effort) catch {
            error =>
              raise @subagent.ComposerError::Failed(
                "child effort selection failed: " + error.to_string(),
              )
          }
        None => ()
      }
      child as &@posoco.Extension
    }
    Magpie(binding) => {
      let child_config = @magpie.MagpieConfig::MagpieConfig(
        base_url=binding.config.base_url,
        credential=binding.config.credential,
        connect_timeout_ms=binding.config.connect_timeout_ms,
        enabled=binding.config.enabled,
        selected_model=Some(spec_slot),
        selected_effort=spec_effort,
      ) catch {
        error =>
          raise @subagent.ComposerError::Failed(
            "child configuration invalid: " + error.to_string(),
          )
      }
      let manager = @magpie.MagpieManager::MagpieManager(
        config=child_config,
        transport=binding.transport,
      )
      // Child execution reports are dropped: subagent usage is not attributed
      // to the parent's operation log. The child manifest carries only the
      // model port — the runtime's commands and lifecycle are parent-only.
      let ext = MagpieChildModel::MagpieChildModel(
        manager~,
        port=@magpie.MagpieModelPort::MagpieModelPort(
          manager~,
          transport=binding.transport,
          report_sink=fn(_report) { () },
        ),
      )
      ext as &@posoco.Extension
    }
  }
}

///|
/// Extension shell for a subagent's Magpie ModelPort. The parent runtime
/// owns commands and lifecycle; a child needs exactly one model port.
priv struct MagpieChildModel {
  manager : @magpie.MagpieManager
  port : @magpie.MagpieModelPort
}

///|
fn MagpieChildModel::MagpieChildModel(
  manager~ : @magpie.MagpieManager,
  port~ : @magpie.MagpieModelPort,
) -> MagpieChildModel {
  { manager, port, }
}

///|
impl @posoco.Extension for MagpieChildModel with fn extension_id(
  _self : MagpieChildModel,
) -> String {
  "cetas_console.magpie_child_model"
}

///|
impl @posoco.Extension for MagpieChildModel with fn manifest(
  self : MagpieChildModel,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="cetas_console.magpie_child_model",
    models=[self.port],
    lifecycle=[self],
  )
}

///|
impl @posoco.Lifecycle for MagpieChildModel with fn on_start(
  self : MagpieChildModel,
) -> Unit {
  try {
    let _ = self.manager.refresh()
  } catch {
    _ => ()
  }
}

///|
impl @posoco.Lifecycle for MagpieChildModel with fn on_shutdown(
  _self : MagpieChildModel,
) -> Unit {
  ()
}

///|
fn magpie_origin_error() -> @posoco.CompositionError {
  @posoco.CompositionError::ManifestSchemaError(
    manifest_id="cetas-console.magpie",
    detail="gateway must be an HTTPS origin or loopback HTTP origin",
  )
}

///|
fn slice_chars(chars : Array[Char], start : Int32, end : Int32) -> String {
  let b = StringBuilder()
  for index in start..<end {
    b.write_char(chars[index])
  }
  b.to_string()
}

///|
fn slice_str(text : String, start : Int32, end : Int32) -> String {
  let chars : Array[Char] = []
  for ch in text {
    chars.push(ch)
  }
  slice_chars(chars, start, end)
}

///|
/// Validate a Magpie gateway origin and return its normalized origin.
/// HTTPS accepts any host; HTTP is loopback-only. Userinfo, query, fragment
/// and any non-root path are rejected; default ports are stripped the way
/// URL.origin does in the cetas-js `validateMagpieAddress` contract — the two
/// hosts must accept the same gateways.
fn validate_magpie_origin(
  url : String,
) -> String raise @posoco.CompositionError {
  let chars : Array[Char] = []
  for ch in url {
    chars.push(ch)
  }
  let mut scheme_end = -1
  for i, ch in url {
    if ch == ':' {
      scheme_end = i
      break
    }
  }
  if scheme_end <= 0 ||
    scheme_end + 3 > chars.length() ||
    chars[scheme_end + 1] != '/' ||
    chars[scheme_end + 2] != '/' {
    raise magpie_origin_error()
  }
  let scheme = slice_chars(chars, 0, scheme_end)
  if scheme != "https" && scheme != "http" {
    raise magpie_origin_error()
  }
  // The authority ends at the first '/', and only a bare root path may
  // follow; userinfo, query and fragment never belong in a gateway origin.
  let mut authority_end = chars.length()
  let authority_start = scheme_end + 3
  let total = chars.length()
  for i in authority_start..<total {
    let ch = chars[i]
    if ch == '@' || ch == '?' || ch == '#' {
      raise magpie_origin_error()
    }
    if ch == '/' {
      authority_end = i
      break
    }
  }
  if authority_end < chars.length() && authority_end + 1 != chars.length() {
    raise magpie_origin_error()
  }
  let authority = slice_chars(chars, scheme_end + 3, authority_end)
  if authority == "" {
    raise magpie_origin_error()
  }
  // Split host and port: bracket-aware for IPv6 literals like [::1].
  let mut host = authority
  let mut port = ""
  if authority.has_prefix("[") {
    let mut closing = -1
    for i, ch in authority {
      if ch == ']' {
        closing = i
        break
      }
    }
    if closing < 0 {
      raise magpie_origin_error()
    }
    host = slice_str(authority, 0, closing + 1)
    port = slice_str(authority, closing + 1, authority.length())
    if port == "" {
      // Bracket literal without a port is fine.
    } else if port.has_prefix(":") {
      port = slice_str(port, 1, port.length())
    } else {
      raise magpie_origin_error()
    }
  } else {
    let mut colon = -1
    for i, ch in authority {
      if ch == ':' {
        colon = i
      }
    }
    if colon >= 0 {
      host = slice_str(authority, 0, colon)
      port = slice_str(authority, colon + 1, authority.length())
    }
  }
  if host == "" {
    raise magpie_origin_error()
  }
  for ch in port {
    if ch < '0' || ch > '9' {
      raise magpie_origin_error()
    }
  }
  // Host names are case-insensitive: lowercase ASCII before loopback checks.
  let lowered = StringBuilder()
  for ch in host {
    if ch >= 'A' && ch <= 'Z' {
      lowered.write_char((ch.to_int() + 32).unsafe_to_char())
    } else {
      lowered.write_char(ch)
    }
  }
  let host_key = lowered.to_string()
  let loopback = host_key == "127.0.0.1" ||
    host_key == "localhost" ||
    host_key == "[::1]" ||
    host_key == "::1"
  if scheme == "http" && !loopback {
    raise magpie_origin_error()
  }
  // URL.origin normalizes the host to lowercase.
  let default_port = if scheme == "http" { "80" } else { "443" }
  if port == default_port || port == "" {
    scheme + "://" + host_key
  } else {
    scheme + "://" + host_key + ":" + port
  }
}

///|
/// Return the settings JSON with the gateway origin configured: the `magpie`
/// section gains `base_url` and `enabled: true` (created when missing); every
/// other key survives untouched. Mirrors cetas-js `writeMagpieAddress`.
fn merge_magpie_address(
  settings : Json,
  origin~ : String,
) -> Json raise @posoco.CompositionError {
  let fields = match settings {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-console.magpie",
        detail="settings.json must be an object",
      )
  }
  let magpie : Map[String, Json] = match fields.get("magpie") {
    Some(Json::Object(inner)) => inner
    _ => Map::from_array([])
  }
  magpie["base_url"] = Json::string(origin)
  magpie["enabled"] = Json::boolean(true)
  fields["magpie"] = Json::object(magpie)
  Json::object(fields)
}

///|
/// Persist the gateway origin into `~/.cetas/settings.json`, preserving every
/// unrelated key, with an atomic write. A missing file starts from `{}`.
async fn write_magpie_address(
  fs : &@workspace.WorkspaceFs,
  home~ : String,
  origin~ : String,
) -> Unit raise @posoco.CompositionError {
  let path = home + "/.cetas/settings.json"
  let current = match @workspace.read_file_result(fs, path) {
    Missing => Json::object(Map::from_array([]))
    Failed(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-console.magpie",
        detail=".cetas/settings.json read failed: " + message,
      )
    Content(text) =>
      @json.parse(text) catch {
        _ =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="cetas-console.magpie",
            detail=".cetas/settings.json is not valid JSON",
          )
      }
  }
  let merged = merge_magpie_address(current, origin~)
  fs.write_file_atomic(path, merged.stringify(indent=2) + "\n") catch {
    @workspace.WorkspaceFsError::WorkspaceFsError(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-console.magpie",
        detail=".cetas/settings.json write failed: " + message,
      )
  }
}

///|
/// Probe the gateway with a throwaway manager: one hello + one models
/// request. The key travels only inside this probe's Authorization header and
/// is never written before the probe succeeds.
async fn test_magpie_connection(
  origin~ : String,
  key~ : String,
) -> Unit raise @posoco.CompositionError {
  let config = @magpie.MagpieConfig::MagpieConfig(
    base_url=origin,
    credential=if key == "" { None } else { Some(key) },
    enabled=true,
  ) catch {
    error =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-console.magpie",
        detail="invalid gateway address: " + error.to_string(),
      )
  }
  let manager = @magpie.MagpieManager::MagpieManager(
    config~,
    transport=@magpie.magpie_http_transport(),
  )
  let _ = manager.refresh() catch {
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-console.magpie",
        detail="gateway connection or authentication failed",
      )
  }
}

///|
/// Retire every live handle and recompose the active session. Both manager
/// switches (settings rewritten) and gateway reconfiguration under a live
/// Magpie manager share this; callers own rollback.
async fn ConsoleRuntime::recompose_all_handles(
  self : ConsoleRuntime,
) -> Result[Json, String] noraise {
  for _, workspace in self.workspaces {
    for _, handle in workspace.handles {
      release_handle_scope(handle) catch {
        _ => ()
      }
    }
    workspace.handles.clear()
  }
  let workspace = self.active()
  match self.compose_handle(workspace, workspace.active_id) {
    Ok(_) => {
      self.emit_active_snapshot()
      Ok(self.runtime_json())
    }
    Err(message) => Err(message)
  }
}

///|
async fn ConsoleRuntime::restore_settings_snapshot(
  self : ConsoleRuntime,
  path : String,
  snapshot : String?,
) -> Unit noraise {
  match snapshot {
    Some(text) => self.fs.write_file_atomic(path, text) catch { _ => () }
    None => ignore(self.fs.remove(path) catch { _ => () })
  }
}

///|
/// Verify and persist a Magpie gateway configuration. The origin is
/// validated before any authenticated request, the connection is probed with
/// a throwaway manager before anything is written, and a failed persistence
/// step restores the previous settings text. A live Magpie manager
/// recomposes so the new origin takes effect without a restart.
pub async fn ConsoleRuntime::configure_magpie(
  self : ConsoleRuntime,
  url~ : String,
  key~ : String,
) -> Result[Json, String] noraise {
  for _, workspace in self.workspaces {
    for _, handle in workspace.handles {
      if handle.busy {
        return Err("gateway setup requires an idle session")
      }
    }
  }
  let origin = validate_magpie_origin(url) catch {
    error => return Err(error.to_string())
  }
  let settings_path = self.home + "/.cetas/settings.json"
  let snapshot : String? = match
    @workspace.read_file_result(self.fs, settings_path) {
    Content(text) => Some(text)
    _ => None
  }
  test_magpie_connection(origin~, key~) catch {
    _ => return Err("gateway connection or authentication failed")
  }
  write_magpie_address(self.fs, home=self.home, origin~) catch {
    _ => return Err("gateway address could not be persisted")
  }
  if key != "" {
    // The credential is written only after the probe and the address
    // succeeded; a failed write rolls the address back.
    credential_store(self.fs, self.home).write(
      MAGPIE_PROVIDER_ID,
      @oauth.ProviderCredential::ApiKey(
        @oauth.ApiKeyCredential::ApiKeyCredential(secret=key),
      ),
    ) catch {
      _ => {
        self.restore_settings_snapshot(settings_path, snapshot)
        return Err("gateway credential could not be saved")
      }
    }
  }
  // A live Magpie manager must see the new origin; the providers manager is
  // untouched.
  let current = match @workspace.read_file_result(self.fs, settings_path) {
    Content(text) => {
      let json = @json.parse(text) catch {
        _ => Json::object(Map::from_array([]))
      }
      @cetas_core.parse_model_manager_choice(json) catch {
        _ => "providers"
      }
    }
    _ => "providers"
  }
  if current == "magpie" {
    match self.recompose_all_handles() {
      Ok(_) => ()
      Err(message) => {
        self.restore_settings_snapshot(settings_path, snapshot)
        match self.recompose_all_handles() {
          Ok(_) =>
            return Err(
              "gateway configured but the recompose failed: \{message}; the previous gateway was restored",
            )
          Err(recovery) =>
            return Err(
              "gateway configured but the recompose failed: \{message}; recovery failed: \{recovery}",
            )
        }
      }
    }
  }
  Ok(
    Json::object(
      Map::from_array([
        ("status", Json::string("configured")),
        ("origin", Json::string(origin)),
      ]),
    ),
  )
}

///|
/// The interactive `/login magpie` flow. Prompts ride the same UiRequest seam
/// as provider logins (select, then origin and key through the secret-input
/// port, so the key is never echoed). The reply matches the provider login
/// outcome shape; failures stay detail-free because gateway errors can echo
/// credentials.
pub async fn ConsoleRuntime::login_magpie(self : ConsoleRuntime) -> Json {
  for _, workspace in self.workspaces {
    for _, handle in workspace.handles {
      if handle.busy {
        return Json::object(
          Map::from_array([
            ("type", Json::string("failure")),
            (
              "reason",
              Json::string("gateway setup requires an idle application"),
            ),
          ]),
        )
      }
    }
  }
  let session_id = self.active_session_id()
  let outcome : Result[String, String] = try {
    let ui : &@posoco.UiPort = HubUiPort::new_secret(
      self.hub,
      self.ui_registry,
      session_id,
      native_ui=self.native_ui,
    )
    let mode = ui.request(
      @posoco.UiRequest::Select(
        prompt="Magpie Gateway",
        options=[
          "Local Gateway — http://127.0.0.1:3425", "Remote Gateway — HTTPS with Gateway Key",
        ],
        default=None,
      ),
    )
    let pair : (String, String) = match mode {
      @posoco.UiResponse::Selected(index) =>
        if index == 0 {
          ("http://127.0.0.1:3425", "")
        } else {
          let url = match
            ui.request(
              @posoco.UiRequest::Input(
                prompt="Gateway HTTPS origin",
                default=None,
              ),
            ) {
            @posoco.UiResponse::Text(value) => value
            _ => return failure_json_magpie()
          }
          let key = match
            ui.request(
              @posoco.UiRequest::Input(
                prompt="Gateway Key (input hidden)",
                default=None,
              ),
            ) {
            @posoco.UiResponse::Text(value) => value
            _ => return failure_json_magpie()
          }
          (url, key)
        }
      _ => return failure_json_magpie()
    }
    let configured = self.configure_magpie(url=pair.0, key=pair.1)
    match configured {
      Ok(state) => {
        let origin = match state {
          Json::Object(fields) =>
            match fields.get("origin") {
              Some(Json::String(value)) => value
              _ => ""
            }
          _ => ""
        }
        Ok(origin)
      }
      Err(message) => Err(message)
    }
  } catch {
    _ => Err("gateway setup was cancelled or failed")
  } noraise {
    value => value
  }
  match outcome {
    Ok(origin) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("success")),
          (
            "feedback",
            Json::string("Magpie Gateway verified and configured: " + origin),
          ),
        ]),
      )
    Err(_) => failure_json_magpie()
  }
}

///|
fn failure_json_magpie() -> Json {
  Json::object(
    Map::from_array([
      ("type", Json::string("failure")),
      (
        "reason",
        Json::string("gateway setup cancelled, unavailable or invalid"),
      ),
    ]),
  )
}
