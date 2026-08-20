///|
/// active_model.mbt — Persisted active model selection shared by every cetas
/// host.
///
/// The selection lives as flat top-level keys in `~/.cetas/settings.json`,
/// next to `providers`:
///
/// ```json
/// { "providers": { ... }, "model": "qwen/glm-4.6", "reasoning_effort": "high" }
/// ```
///
/// `model` holds the router slot id (`provider/model`); `reasoning_effort`
/// is optional and falls back to the slot's advertised default when absent or
/// no longer supported. Hosts read the selection at composition; cetas-js
/// writes it back after every successful `/model` or `/effort`, and cetas-acp
/// after every successful `session/set_config_option`, so the choice survives
/// restarts instead of resetting to the first catalog slot.

///|
/// The persisted selection: router slot id plus an optional effort override.
pub struct ActiveModelSelection {
  slot : String
  effort : String?
}

///|
pub fn ActiveModelSelection::new(
  slot : String,
  effort? : String,
) -> ActiveModelSelection {
  { slot, effort }
}

///|
/// Build from already-optional state (e.g. `RouterModelPort::active_effort`),
/// where the caller holds an `Option` instead of a literal.
pub fn ActiveModelSelection::from_current(
  slot : String,
  effort : String?,
) -> ActiveModelSelection {
  { slot, effort }
}

///|
let active_model_manifest_id : String = "cetas.active_model"

///|
/// Parse the flat selection keys from the top-level settings JSON. A missing
/// `model` key means no persisted selection (normal first-run state); a
/// present key with the wrong shape fails loudly instead of being sanitized
/// into a default.
pub fn parse_active_model_selection(
  settings : Json,
) -> ActiveModelSelection? raise @posoco.CompositionError {
  let fields = match settings {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=active_model_manifest_id,
        detail="settings.json must be an object",
      )
  }
  let slot = match fields.get("model") {
    None => return None
    Some(Json::String(slot)) => slot
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=active_model_manifest_id,
        detail="settings.model must be a string",
      )
  }
  let effort = match fields.get("reasoning_effort") {
    None => None
    Some(Json::String(effort)) => Some(effort)
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=active_model_manifest_id,
        detail="settings.reasoning_effort must be a string",
      )
  }
  Some({ slot, effort })
}

///|
/// Return the settings JSON with the flat selection keys replaced. Every
/// other key (including unknown ones) survives untouched; a `None` effort
/// removes `reasoning_effort` instead of writing a null. The input must be
/// an object — a malformed root fails loudly so the write path never
/// clobbers the file with a fresh `{}` over unreadable content.
pub fn merge_active_model_selection(
  settings : Json,
  selection : ActiveModelSelection,
) -> Json raise @posoco.CompositionError {
  match settings {
    Json::Object(fields) => {
      fields["model"] = Json::string(selection.slot)
      match selection.effort {
        Some(effort) => fields["reasoning_effort"] = Json::string(effort)
        None => ignore(fields.remove("reasoning_effort"))
      }
      Json::object(fields)
    }
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=active_model_manifest_id,
        detail="settings.json must be an object",
      )
  }
}

///|
/// Resolve the persisted selection to a `RouterModelPort::from_catalogs`
/// `default_slot_id`. `""` keeps the router's first-slot default: either no
/// selection exists, or the selected slot drifted away (provider
/// unconfigured since) — a drifted selection must not fail composition.
pub fn resolve_default_slot_id(
  catalogs : Array[@llm.ProviderModelCatalog],
  selection : ActiveModelSelection?,
) -> String {
  match selection {
    None => ""
    Some(selected) => {
      for catalog in catalogs {
        for slot in catalog.slots {
          if slot.id == selected.slot {
            return selected.slot
          }
        }
      }
      ""
    }
  }
}

///|
/// Read the persisted selection from `~/.cetas/settings.json`. A missing
/// file is a normal no-selection state; unreadable or malformed content
/// fails loudly.
pub async fn read_active_model_selection(
  fs : &@workspace.WorkspaceFs,
  home~ : String,
) -> ActiveModelSelection? raise @posoco.CompositionError {
  match @workspace.read_file_result(fs, home + "/.cetas/settings.json") {
    Missing => None
    Failed(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=active_model_manifest_id,
        detail=".cetas/settings.json read failed: " + message,
      )
    Content(text) => {
      let json = @json.parse(text) catch {
        _ =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id=active_model_manifest_id,
            detail=".cetas/settings.json is not valid JSON",
          )
      }
      parse_active_model_selection(json)
    }
  }
}

///|
/// Persist the selection into `~/.cetas/settings.json`, preserving every
/// unrelated key, with an atomic write. A missing file starts from `{}`.
pub async fn write_active_model_selection(
  fs : &@workspace.WorkspaceFs,
  home~ : String,
  selection : ActiveModelSelection,
) -> Unit raise @posoco.CompositionError {
  let path = home + "/.cetas/settings.json"
  let current = match @workspace.read_file_result(fs, path) {
    Missing => Json::object(Map::from_array([]))
    Failed(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=active_model_manifest_id,
        detail=".cetas/settings.json read failed: " + message,
      )
    Content(text) =>
      @json.parse(text) catch {
        _ =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id=active_model_manifest_id,
            detail=".cetas/settings.json is not valid JSON",
          )
      }
  }
  let merged = merge_active_model_selection(current, selection)
  fs.write_file_atomic(path, merged.stringify(indent=2) + "\n") catch {
    @workspace.WorkspaceFsError::WorkspaceFsError(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=active_model_manifest_id,
        detail=".cetas/settings.json write failed: " + message,
      )
  }
}
