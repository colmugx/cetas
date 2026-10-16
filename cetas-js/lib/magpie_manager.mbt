///|
/// magpie_manager.mbt — host-owned Magpie integration boundary.
///
/// Cetas composes exactly one ModelPort per Agent (Posoco cardinality). The
/// model manager is chosen from `~/.cetas/settings.json` (`model_manager`:
/// the default `"providers"` keeps the ext-llm router, `"magpie"` composes
/// the Magpie runtime instead); switching managers rebuilds the Agent through
/// the existing recompose path. Magpie-specific surfaces (gateway
/// intelligence, routing groups, effort ladders) stay behind this file and
/// behind the runtime's own `magpie_*` commands — ext-llm never sees them.

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
  Providers(@llm.RouterModelPort)
  Magpie(MagpieBinding)
}

///|
/// Parsed `model_manager` / `magpie` sections plus the persisted global
/// `model` / `reasoning_effort` keys. `None` means the providers manager.
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
  warn~ : (String) -> Unit,
) -> MagpieHostSettings? raise @posoco.CompositionError {
  let text = match
    @workspace.read_file_result(fs, home + "/.cetas/settings.json") {
    Missing => return None
    Failed(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-js.magpie",
        detail=".cetas/settings.json read failed: " + message,
      )
    Content(text) => text
  }
  let json = @json.parse(text) catch {
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-js.magpie",
        detail=".cetas/settings.json is not valid JSON",
      )
  }
  guard json is Json::Object(fields) else {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="cetas-js.magpie",
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
            manifest_id="cetas-js.magpie",
            detail="settings.magpie.base_url must be a string",
          )
      }
      match magpie.get("enabled") {
        Some(Json::True) => enabled = true
        Some(Json::False) => enabled = false
        Some(Json::Null) | None => ()
        Some(_) =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="cetas-js.magpie",
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
        manifest_id="cetas-js.magpie",
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
        manifest_id="cetas-js.magpie",
        detail="settings.model must be a string",
      )
  }
  match fields.get("reasoning_effort") {
    Some(Json::String(value)) => effort = Some(value)
    Some(Json::Null) | None => ()
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-js.magpie",
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
  // Child managers (subagents) rebuild from the same endpoint material with their
  // own selection state; a degraded activation's defaults are safe to reuse.
  let config_error = fn(message : String) -> @posoco.CompositionError {
    @posoco.CompositionError::ManifestSchemaError(
      manifest_id="cetas-js.magpie",
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
/// The composed extension contributing the single ModelPort.
fn ModelManagerFace::manager_extension(
  self : ModelManagerFace,
) -> &@posoco.Extension {
  match self {
    Providers(router) => router as &@posoco.Extension
    Magpie(binding) => binding.runtime as &@posoco.Extension
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
fn ModelManagerFace::manager_active_model_id(self : ModelManagerFace) -> String {
  self.manager_control().active_selection().model_id
}

///|
fn ModelManagerFace::manager_active_effort(self : ModelManagerFace) -> String? {
  self.manager_control().active_selection().effort
}

///|
/// Each adapter fulfills the same devkit status contract. The ext-llm
/// manager already owns the "model" segment; its status publisher remains
/// authoritative. The Magpie adapter owns its own "model" segment. Both
/// publish a manager label through the same bus. No UI needs to know either.
fn ModelManagerFace::manager_publish_status(
  self : ModelManagerFace,
  bus : @devkit.EventBus,
) -> Unit {
  let control = self.manager_control()
  let selection = control.active_selection()
  let label = match self {
    Providers(_) => "Posoco"
    Magpie(_) => "Magpie"
  }
  @devkit.publish_status_register(
    bus,
    source="cetas.model_manager",
    segment="manager",
    priority=21,
    value=label,
  )
  match self {
    Providers(_) => () // ext-llm owns and publishes its model status.
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
      @devkit.publish_status_register(
        bus,
        source="cetas.model_manager",
        segment="model",
        priority=20,
        value=selection.model_id + ":" + effort,
      )
    }
  }
}

///|
/// Apply a model and/or effort selection. Unknown models and unadvertised
/// efforts raise — the callers surface the failure instead of silently
/// switching to another model.
fn ModelManagerFace::manager_select(
  self : ModelManagerFace,
  model? : String,
  effort? : String,
) -> Unit raise @posoco.CommandError {
  match self {
    Providers(router) => {
      match model {
        Some(slot) =>
          router.switch_slot(slot) catch {
            error =>
              raise @posoco.CommandError::InvalidArgs(reason=error.to_string())
          }
        None => ()
      }
      match effort {
        Some(value) =>
          router.select_effort(model.unwrap_or(router.active_slot_id()), value) catch {
            error =>
              raise @posoco.CommandError::InvalidArgs(reason=error.to_string())
          }
        None => ()
      }
    }
    Magpie(binding) => {
      let manager = binding.runtime.manager()
      match model {
        Some(model_id) =>
          manager.select_model(model_id) catch {
            error =>
              raise @posoco.CommandError::InvalidArgs(reason=error.to_string())
          }
        None => ()
      }
      match effort {
        Some(value) =>
          manager.select_effort(value) catch {
            error =>
              raise @posoco.CommandError::InvalidArgs(reason=error.to_string())
          }
        None => ()
      }
    }
  }
}

///|
fn ModelManagerFace::manager_supports_images(self : ModelManagerFace) -> Bool {
  match self {
    Providers(router) => {
      let active_id = router.active_slot_id()
      for slot in router.list_slots() {
        if slot.id == active_id {
          return slot.capabilities.contains("image_in")
        }
      }
      false
    }
    Magpie(binding) => {
      let selection = binding.runtime.manager().active_selection()
      match binding.runtime.manager().catalog_entry(selection.model_id) {
        Some(entry) =>
          entry.meta.modalities_input is Some(inputs) &&
          inputs.contains("image")
        None => false
      }
    }
  }
}

///|
/// `/model` catalog entries in the shared picker shape. The Magpie variant
/// maps the manager catalog into the router entry fields one-for-one; the
/// provider field stays the fixed "magpie" group so the picker keeps Magpie
/// entries visibly separate from ordinary providers. Effort values pass
/// through verbatim — Magpie ladders are never normalized.
fn ModelManagerFace::manager_catalog_entries_json(
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
        let capabilities : Array[Json] = model.capabilities.map(fn(capability) {
          Json::string(capability)
        })
        let efforts : Array[Json] = model.efforts.map(fn(effort) {
          Json::string(effort)
        })
        Json::object({
          "id": Json::string(model.model_id),
          "label": Json::string(model.label),
          "provider": Json::string(MAGPIE_PICKER_PROVIDER),
          "model": Json::string(model.model_id),
          "active": Json::boolean(model.model_id == selection.model_id),
          "active_effort": match selection.effort {
            Some(effort) => Json::string(effort)
            None => Json::null()
          },
          "thinking_efforts": Json::array(efforts),
          "context_window": match model.context_window {
            Some(window) => Json::number(window.to_double())
            None => Json::null()
          },
          "capabilities": Json::array(capabilities),
          "default_effort": match model.default_effort {
            Some(effort) => Json::string(effort)
            None => Json::null()
          },
          "group": match manager.catalog_entry(model.model_id) {
            Some(entry) =>
              if entry.meta.is_routing_group {
                Json::string("Routing Groups")
              } else {
                Json::string(@devkit.sanitize_label(entry.meta.provider_id))
              }
            None => Json::null()
          },
          "pending": Json::boolean(selection.pending),
        })
      })
    }
  }
}

///|
/// Pending-selection annotation for the catalog feedback line: a pending
/// selection must stay visible instead of silently reading as applied.
fn ModelManagerFace::manager_pending_note(self : ModelManagerFace) -> String {
  match self {
    Providers(_) => ""
    Magpie(binding) => {
      let selection = binding.runtime.manager().active_selection()
      if selection.pending {
        " (selection '" +
        selection.model_id +
        "' is pending: not in the catalog yet; requests will fail until a refresh provides it)"
      } else {
        ""
      }
    }
  }
}

///|
/// Magpie's row in `describe_setup`: one provider-shaped entry so the host's
/// needs-setup logic and login surface treat it like any configured provider.
fn magpie_setup_entry_json(binding : MagpieBinding) -> Json {
  let selection = binding.runtime.manager().active_selection()
  Json::object({
    "id": Json::string(MAGPIE_PROVIDER_ID),
    "label": Json::string("Magpie"),
    "provider": Json::string(MAGPIE_PICKER_PROVIDER),
    "model": Json::string(selection.model_id),
    "active": Json::boolean(true),
    "efforts": Json::array([]),
    "oauth": Json::boolean(false),
  })
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
      let child = @llm.RouterModelPort(
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
  "cetas_js.magpie_child_model"
}

///|
impl @posoco.Extension for MagpieChildModel with fn manifest(
  self : MagpieChildModel,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="cetas_js.magpie_child_model",
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
