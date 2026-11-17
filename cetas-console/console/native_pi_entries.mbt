///|
/// The native SessionPort is the only authority for persisted Pi custom data.
/// The Bun guest may submit opaque entries, but never receives a file path or
/// permission to mutate the native session journal directly.
const NATIVE_PI_ENTRIES_KEY : String = "pi.custom_entries"

///|
pub async fn ConsoleRuntime::pi_guest_entries_json(
  self : ConsoleRuntime,
  session_id : String,
) -> Result[Json, String] {
  for _, workspace in self.workspaces {
    match workspace.handles.get(session_id) {
      Some(_) => {
        let loaded : Result[@posoco.Session, Error] = Ok(
          (workspace.platform.session_store as &@posoco.SessionPort).load(
            session_id,
          ),
        ) catch {
          error => Err(error)
        }
        let entries = match loaded {
          Ok(session) =>
            match session.metadata.get(NATIVE_PI_ENTRIES_KEY) {
              Some(Json::Array(items)) => Json::array(items)
              _ => Json::array([])
            }
          Err(_) => Json::array([])
        }
        return Ok(
          Json::object({
            "session_id": Json::string(session_id),
            "entries": entries,
          }),
        )
      }
      None => ()
    }
  }
  Err("Pi guest session not found: " + session_id)
}

///|
/// Append idempotently only while the owning native Agent is idle. The Go
/// bridge queues pending entries and retries after the next safe boundary;
/// neither Bun nor an EventHub observer can write during a running turn.
pub async fn ConsoleRuntime::pi_guest_append_entries(
  self : ConsoleRuntime,
  session_id : String,
  entries : Json,
) -> Result[Int32, String] {
  let submitted = match entries {
    Json::Array(items) => items
    _ => return Err("Pi custom entries must be an array")
  }
  if submitted.length() > 64 {
    return Err("Pi custom entry batch exceeds 64 entries")
  }
  for _, workspace in self.workspaces {
    match workspace.handles.get(session_id) {
      Some(handle) => {
        if handle.busy {
          return Err("Pi session is busy; retry after the native turn")
        }
        let store = workspace.platform.session_store as &@posoco.SessionPort
        let loaded : Result[@posoco.Session, Error] = Ok(
          store.load(session_id),
        ) catch {
          error => Err(error)
        }
        let session = match loaded {
          Ok(value) => value
          Err(_) => @posoco.Session::{
            messages: [],
            metadata: Map::from_array([]),
          }
        }
        let merged : Array[Json] = match session.metadata.get(
          NATIVE_PI_ENTRIES_KEY,
        ) {
          Some(Json::Array(items)) => items.copy()
          _ => []
        }
        let seen : Map[String, Bool] = Map::from_array([])
        for item in merged {
          match item {
            Json::Object(fields) =>
              match fields.get("id") {
                Some(Json::String(id)) => seen[id] = true
                _ => ()
              }
            _ => ()
          }
        }
        let mut added = 0
        for entry in submitted {
          guard entry is Json::Object(fields) else {
            return Err("Pi custom entry must be an object")
          }
          let id = match fields.get("id") {
            Some(Json::String(id)) if !id.is_empty() => id
            _ => return Err("Pi custom entry needs an ID")
          }
          let custom_type = match fields.get("customType") {
            Some(Json::String(value)) if !value.is_empty() => value
            _ => return Err("Pi custom entry needs a customType")
          }
          let data = fields.get("data").unwrap_or(Json::null())
          if !seen.contains(id) {
            if merged.length() >= 1024 {
              return Err("Pi custom entry journal reached its 1024-entry limit")
            }
            merged.push(Json::object({
              "id": Json::string(id),
              "customType": Json::string(custom_type),
              "data": data,
            }))
            seen[id] = true
            added += 1
          }
        }
        if added == 0 {
          return Ok(0)
        }
        let metadata = session.metadata.copy()
        metadata[NATIVE_PI_ENTRIES_KEY] = Json::array(merged)
        let saved : Result[Unit, Error] = Ok(
          store.save(session_id, {
            messages: session.messages,
            metadata,
          }),
        ) catch {
          error => Err(error)
        }
        return match saved {
          Ok(_) => Ok(added)
          Err(error) => Err("Pi custom entry persist failed: " + error.to_string())
        }
      }
      None => ()
    }
  }
  Err("Pi guest session not found: " + session_id)
}
