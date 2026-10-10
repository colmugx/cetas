///|
/// Workspace registry: `~/.cetas/console-workspaces.json` keeps the list of
/// directory paths the console has opened, so workspaces survive restarts
/// and are shared by every console host (web, desktop).
fn registry_path(home : String) -> String {
  home + "/.cetas/console-workspaces.json"
}

///|
/// Legacy web-host registry; read once for migration when the console
/// registry does not exist yet.
fn legacy_registry_path(home : String) -> String {
  home + "/.cetas/web-workspaces.json"
}

///|
fn parse_registry(data : String) -> Array[String] {
  let json = @json.parse(data) catch { _ => return [] }
  let cwds : Array[String] = []
  guard json is Json::Array(items) else { return cwds }
  for item in items {
    if item is Json::String(cwd) {
      cwds.push(cwd)
    }
  }
  cwds
}

///|
async fn load_registry(home : String) -> Array[String] {
  let data = @fs.read_file(registry_path(home))
  parse_registry(data.text())
}

///|
async fn load_registry_with_legacy(home : String) -> Array[String] {
  try {
    return load_registry(home)
  } catch {
    _ => ()
  }
  let data = @fs.read_file(legacy_registry_path(home))
  parse_registry(data.text())
}

///|
async fn save_registry(home : String, cwds : Array[String]) -> Unit {
  let items : Array[Json] = []
  for cwd in cwds {
    items.push(Json::string(cwd))
  }
  @fs.write_file(
    registry_path(home),
    Json::array(items).stringify(),
    create_mode=OpenOrCreate,
  )
}
