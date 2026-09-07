///|
/// model_cache.mbt — Disk cache of discovered model lists, shared by every
/// cetas host. `~/.cetas/model_lists.json` holds one record array per
/// provider id — the projection of a refreshed provider catalog. Hosts seed
/// composition with the cache so a restart announces the full model list
/// without a network request; the cache is wholly derived, re-derivable
/// data, so it never fails composition: reads degrade to an empty cache
/// (the caller warns once) and writes self-heal a malformed root.

///|
/// Extract the per-provider record arrays from the cache root. Any
/// non-object root yields an empty cache — providers then build their
/// static catalogs as if no cache existed.
pub fn parse_model_list_cache(json : Json) -> Map[String, Json] {
  match json {
    Json::Object(fields) => fields
    _ => Map::from_array([])
  }
}

///|
/// Read `~/.cetas/model_lists.json`: a missing file is a normal cold state
/// (`Ok` with an empty map); an unreadable or malformed file is `Err` — the
/// caller warns and continues without the cache.
pub async fn read_model_list_cache(
  fs : &@workspace.WorkspaceFs,
  home~ : String,
) -> Result[Map[String, Json], String] noraise {
  match @workspace.read_file_result(fs, home + "/.cetas/model_lists.json") {
    Missing => Ok(Map::from_array([]))
    Failed(message) => Err(".cetas/model_lists.json read failed: " + message)
    Content(text) => {
      let json = @json.parse(text) catch {
        _ => return Err(".cetas/model_lists.json is not valid JSON")
      }
      Ok(parse_model_list_cache(json))
    }
  }
}

///|
/// Project one refreshed catalog into its cache record array, preserving
/// slot order: exactly the serializable discovery facts providers need to
/// rebuild slots offline. Labels and display groups are excluded — every
/// provider regenerates them deterministically.
pub fn catalog_model_records(catalog : @llm.ProviderModelCatalog) -> Json {
  let items : Array[Json] = []
  for slot in catalog.slots() {
    let efforts : Array[Json] = []
    for effort in slot.thinking_efforts {
      efforts.push(Json::string(effort))
    }
    items.push(
      Json::object(
        Map::from_array([
          ("model_id", Json::string(slot.model_id)),
          ("thinking_efforts", Json::array(efforts)),
          (
            "default_effort",
            match slot.default_effort {
              Some(effort) => Json::string(effort)
              None => Json::null()
            },
          ),
          (
            "context_window",
            match slot.context_window {
              Some(value) => Json::number(value.to_double())
              None => Json::null()
            },
          ),
          ("image_in", Json::boolean(slot.capabilities.contains("image_in"))),
        ]),
      ),
    )
  }
  Json::array(items)
}

///|
/// Return the cache root with one provider's records replaced. Unknown
/// providers and keys survive untouched; a non-object root is replaced with
/// a fresh object — wholly derived data has no malformed state worth
/// preserving.
pub fn merge_model_list_cache(
  existing : Json,
  provider_id : String,
  records : Json,
) -> Json {
  let fields = match existing {
    Json::Object(fields) => fields
    _ => Map::from_array([])
  }
  fields[provider_id] = records
  Json::object(fields)
}

///|
/// Persist one provider's refreshed records into `~/.cetas/model_lists.json`
/// atomically; a missing or malformed file starts from a fresh object.
pub async fn write_model_list_cache(
  fs : &@workspace.WorkspaceFs,
  home~ : String,
  provider_id : String,
  records : Json,
) -> Unit raise @posoco.CompositionError {
  let dir = home + "/.cetas"
  let path = dir + "/model_lists.json"
  let current = match @workspace.read_file_result(fs, path) {
    Missing => Json::object(Map::from_array([]))
    Failed(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas.model_cache",
        detail=".cetas/model_lists.json read failed: " + message,
      )
    Content(text) =>
      @json.parse(text) catch {
        _ => Json::object(Map::from_array([]))
      }
  }
  let merged = merge_model_list_cache(current, provider_id, records)
  fs.mkdir(dir, recursive=true) catch {
    _ => ()
  }
  fs.write_file_atomic(path, merged.stringify(indent=2) + "\n") catch {
    @workspace.WorkspaceFsError::WorkspaceFsError(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas.model_cache",
        detail=".cetas/model_lists.json write failed: " + message,
      )
  }
}
