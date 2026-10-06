///|
/// Workspace registry: `~/.cetas/web-workspaces.json` keeps the list of
/// directory paths the console has opened, so workspaces survive restarts.
fn registry_path(home : String) -> String {
  home + "/.cetas/web-workspaces.json"
}

///|
async fn load_registry(home : String) -> Array[String] {
  let data = @fs.read_file(registry_path(home))
  let json = @json.parse(data.text())
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
