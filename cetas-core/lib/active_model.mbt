///|
/// active_model.mbt — Persisted active model selection shared by every cetas
/// host.
///
/// The selection lives as flat top-level keys in `~/.cetas/settings.json`,
/// next to `providers`:
///
/// ```json
/// { "providers": { ... }, "model": "qwen/glm-4.6", "reasoning_effort": "high", "decision_model": "zai/glm-4.6-air" }
/// ```
///
/// `model` holds the router slot id (`provider/model`) of the conversation
/// selection; `reasoning_effort` is optional and falls back to the slot's
/// advertised default when absent or unsupported. `decision_model`
/// holds the `kind = Decision` slot id of the `/decision` selection and is
/// independent of `model`: the two selections never cross kinds. Hosts read
/// the selections at composition; cetas-js writes them back after every
/// successful `/model` or `/effort` (and `/decision` for the decision key),
/// and cetas-acp after every successful `session/set_config_option`, so the
/// choices survive restarts instead of resetting to the first catalog slot.

///|
/// The persisted selection: router slot id plus an optional effort override.
pub struct ActiveModelSelection {
  slot : String
  effort : String?
}

///|
pub fn ActiveModelSelection::ActiveModelSelection(
  slot : String,
  effort? : String,
) -> ActiveModelSelection {
  { slot, effort, }
}

///|
/// Build from already-optional state (e.g. `RouterModelPort::active_effort`),
/// where the caller holds an `Option` instead of a literal.
pub fn ActiveModelSelection::from_current(
  slot : String,
  effort : String?,
) -> ActiveModelSelection {
  { slot, effort, }
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
  Some({ slot, effort, })
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
/// The persisted selection resolved against the startup catalogs.
///
/// `Pending` replaces the old "silently fall back to the first catalog slot"
/// policy: a persisted slot that is absent from the catalogs stays selected
/// and requests to it fail visibly until the slot appears (login/refresh).
pub(all) enum ActiveModelRestore {
  /// No persisted selection; the router picks its own default.
  NoSelection
  /// The persisted slot exists in the catalogs; select it normally.
  Selected(slot~ : String)
  /// The persisted slot is absent from the catalogs; keep it selected as a
  /// pending default (router `allow_missing_default`) and warn visibly.
  Pending(slot~ : String)
}

///|
/// Resolve the persisted selection to a `RouterModelPort::from_catalogs`
/// default decision. A present slot resolves to `Selected` only when some
/// catalog still advertises it; otherwise it degrades to `Pending` — never
/// to a different model.
pub fn resolve_active_model_restore(
  catalogs : Array[@llm.ProviderModelCatalog],
  selection : ActiveModelSelection?,
) -> ActiveModelRestore {
  let selected = match selection {
    None => return NoSelection
    Some(selected) => selected
  }
  for catalog in catalogs {
    for slot in catalog.slots {
      if slot.id == selected.slot {
        return Selected(slot=selected.slot)
      }
    }
  }
  Pending(slot=selected.slot)
}

///|
/// Read the persisted selection from `~/.cetas/settings.json`. A missing
/// file is a normal no-selection state; unreadable or malformed content
/// fails loudly.
pub async fn read_active_model_selection(
  fs : &@workspace.WorkspaceFs,
  home~ : String,
) -> ActiveModelSelection? raise @posoco.CompositionError {
  match @workspace.read_file_result(fs, settings_path(home)) {
    Missing => None
    Failed(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=active_model_manifest_id,
        detail=".cetas/settings.json read failed: " + message,
      )
    Content(text) => {
      let json = parse_settings_json(text, manifest_id=active_model_manifest_id)
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
  let path = settings_path(home)
  let current = match @workspace.read_file_result(fs, path) {
    Missing => Json::object(Map::from_array([]))
    Failed(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=active_model_manifest_id,
        detail=".cetas/settings.json read failed: " + message,
      )
    Content(text) =>
      parse_settings_json(text, manifest_id=active_model_manifest_id)
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

///|
/// The persisted active decision model: the `kind = Decision` router slot id
/// written to the top-level `decision_model` key. It sits next to `model` and
/// follows the same contract — the two selections never cross kinds, so a
/// chat slot id must never appear here.
pub struct ActiveDecisionSelection {
  slot : String
}

///|
pub fn ActiveDecisionSelection::ActiveDecisionSelection(
  slot : String,
) -> ActiveDecisionSelection {
  { slot, }
}

///|
let active_decision_manifest_id : String = "cetas.active_decision_model"

///|
/// Parse the flat `decision_model` key from the top-level settings JSON. A
/// missing key means no persisted decision selection (the normal state when
/// the decision capability has never been used); a present key with the
/// wrong shape fails loudly instead of being sanitized into a default.
pub fn parse_active_decision_model_selection(
  settings : Json,
) -> ActiveDecisionSelection? raise @posoco.CompositionError {
  let fields = match settings {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=active_decision_manifest_id,
        detail="settings.json must be an object",
      )
  }
  match fields.get("decision_model") {
    None => None
    Some(Json::String(slot)) => Some({ slot, })
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=active_decision_manifest_id,
        detail="settings.decision_model must be a string",
      )
  }
}

///|
/// Return the settings JSON with the `decision_model` key replaced. Every
/// other key (including `model` and `reasoning_effort`) survives untouched;
/// a `None` selection removes the key instead of writing a null. The input
/// must be an object — a malformed root fails loudly so the write path never
/// clobbers the file with a fresh `{}` over unreadable content.
pub fn merge_active_decision_model_selection(
  settings : Json,
  selection : ActiveDecisionSelection?,
) -> Json raise @posoco.CompositionError {
  match settings {
    Json::Object(fields) => {
      match selection {
        Some(selected) => fields["decision_model"] = Json::string(selected.slot)
        None => ignore(fields.remove("decision_model"))
      }
      Json::object(fields)
    }
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=active_decision_manifest_id,
        detail="settings.json must be an object",
      )
  }
}

///|
/// Read the persisted decision selection from `~/.cetas/settings.json`. A
/// missing file is a normal no-selection state; unreadable or malformed
/// content fails loudly.
pub async fn read_active_decision_model_selection(
  fs : &@workspace.WorkspaceFs,
  home~ : String,
) -> ActiveDecisionSelection? raise @posoco.CompositionError {
  match @workspace.read_file_result(fs, settings_path(home)) {
    Missing => None
    Failed(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=active_decision_manifest_id,
        detail=".cetas/settings.json read failed: " + message,
      )
    Content(text) => {
      let json = parse_settings_json(
        text,
        manifest_id=active_decision_manifest_id,
      )
      parse_active_decision_model_selection(json)
    }
  }
}

///|
/// Persist the decision selection into `~/.cetas/settings.json`, preserving
/// every unrelated key, with an atomic write. A missing file starts from
/// `{}`; a `None` selection removes the `decision_model` key.
pub async fn write_active_decision_model_selection(
  fs : &@workspace.WorkspaceFs,
  home~ : String,
  selection : ActiveDecisionSelection?,
) -> Unit raise @posoco.CompositionError {
  let path = settings_path(home)
  let current = match @workspace.read_file_result(fs, path) {
    Missing => Json::object(Map::from_array([]))
    Failed(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=active_decision_manifest_id,
        detail=".cetas/settings.json read failed: " + message,
      )
    Content(text) =>
      parse_settings_json(text, manifest_id=active_decision_manifest_id)
  }
  let merged = merge_active_decision_model_selection(current, selection)
  fs.write_file_atomic(path, merged.stringify(indent=2) + "\n") catch {
    @workspace.WorkspaceFsError::WorkspaceFsError(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=active_decision_manifest_id,
        detail=".cetas/settings.json write failed: " + message,
      )
  }
}

///|
/// Resolve the persisted decision selection against the startup catalogs.
/// Same vocabulary as `resolve_active_model_restore`: a slot resolves to
/// `Selected` only when some catalog still advertises it as a
/// `kind = Decision` slot; otherwise it degrades to `Pending` — never to a
/// different decision backend.
pub fn resolve_active_decision_model_restore(
  catalogs : Array[@llm.ProviderModelCatalog],
  selection : ActiveDecisionSelection?,
) -> ActiveModelRestore {
  let selected = match selection {
    None => return NoSelection
    Some(selected) => selected
  }
  for catalog in catalogs {
    for slot in catalog.slots {
      if slot.id == selected.slot && slot.is_decision() {
        return Selected(slot=selected.slot)
      }
    }
  }
  Pending(slot=selected.slot)
}

///|
/// The persisted model-manager choice: the flat `model_manager` key next to
/// `model`/`reasoning_effort`. The file is shared with cetas-js, whose
/// manager switch stashes each manager's last selection under
/// `manager_selections` and swaps the top-level keys — the merge below must
/// stay field-for-field identical with that TypeScript logic
/// (`cetas-js/src/app/model-manager-settings.ts`), or the two hosts corrupt
/// each other's settings.
pub fn parse_model_manager_choice(
  settings : Json,
) -> String raise @posoco.CompositionError {
  let fields = match settings {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=active_model_manifest_id,
        detail="settings.json must be an object",
      )
  }
  match fields.get("model_manager") {
    None => "providers"
    Some(Json::String("providers")) => "providers"
    Some(Json::String("magpie")) => "magpie"
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=active_model_manifest_id,
        detail="settings.model_manager must be providers or magpie",
      )
  }
}

///|
/// Return the settings JSON with the model-manager choice switched. The
/// current manager's live top-level selection (`model`, `reasoning_effort`)
/// is stashed into its `manager_selections` entry; the target manager's
/// stashed entry is promoted back to the top level. Every other key
/// (including unknown ones) survives untouched. The input must be an object —
/// a malformed root fails loudly so the write path never clobbers the file.
pub fn merge_model_manager_choice(
  settings : Json,
  choice~ : String,
) -> Json raise @posoco.CompositionError {
  match choice {
    "providers" | "magpie" => ()
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=active_model_manifest_id,
        detail="model manager choice must be providers or magpie",
      )
  }
  let fields = match settings {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=active_model_manifest_id,
        detail="settings.json must be an object",
      )
  }
  let current = match fields.get("model_manager") {
    None => "providers"
    Some(Json::String("providers")) => "providers"
    Some(Json::String("magpie")) => "magpie"
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=active_model_manifest_id,
        detail="settings.model_manager must be providers or magpie",
      )
  }
  let selections : Map[String, Json] = match fields.get("manager_selections") {
    Some(Json::Object(inner)) => inner
    _ => Map::from_array([])
  }
  // Stash the live selection into the current manager's entry. The entry is
  // replaced as a whole (mirroring the JS object spread): a malformed stash
  // value is rewritten, never merged into.
  let source_entry : Map[String, Json] = match selections.get(current) {
    Some(Json::Object(inner)) => inner
    _ => Map::from_array([])
  }
  match fields.get("model") {
    Some(Json::String(model)) => source_entry["model"] = Json::string(model)
    _ => ()
  }
  match fields.get("reasoning_effort") {
    Some(Json::String(effort)) =>
      source_entry["reasoning_effort"] = Json::string(effort)
    _ => ()
  }
  selections[current] = Json::object(source_entry)
  // Promote the target manager's stashed selection back to the top level; a
  // target without a stashed model leaves both keys absent.
  ignore(fields.remove("model"))
  ignore(fields.remove("reasoning_effort"))
  match selections.get(choice) {
    Some(Json::Object(target)) => {
      match target.get("model") {
        Some(Json::String(model)) => fields["model"] = Json::string(model)
        _ => ()
      }
      match target.get("reasoning_effort") {
        Some(Json::String(effort)) =>
          fields["reasoning_effort"] = Json::string(effort)
        _ => ()
      }
    }
    _ => ()
  }
  fields["manager_selections"] = Json::object(selections)
  fields["model_manager"] = Json::string(choice)
  Json::object(fields)
}

///|
/// Persist the model-manager choice into `~/.cetas/settings.json`, preserving
/// every unrelated key, with an atomic write. A missing file starts from `{}`.
pub async fn write_model_manager_choice(
  fs : &@workspace.WorkspaceFs,
  home~ : String,
  choice~ : String,
) -> Unit raise @posoco.CompositionError {
  let path = settings_path(home)
  let current = match @workspace.read_file_result(fs, path) {
    Missing => Json::object(Map::from_array([]))
    Failed(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=active_model_manifest_id,
        detail=".cetas/settings.json read failed: " + message,
      )
    Content(text) =>
      parse_settings_json(text, manifest_id=active_model_manifest_id)
  }
  let merged = merge_model_manager_choice(current, choice~)
  fs.write_file_atomic(path, merged.stringify(indent=2) + "\n") catch {
    @workspace.WorkspaceFsError::WorkspaceFsError(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id=active_model_manifest_id,
        detail=".cetas/settings.json write failed: " + message,
      )
  }
}
