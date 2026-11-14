///|
/// Cetas profile manifest discovery. Profiles are opt-in; an absent directory
/// leaves the existing Cetas feature recipe unchanged. IO belongs to the
/// host's injected WorkspaceFs, not to posoco-ext-profiles.
///
/// The user catalog is applied first, then project entries replace an
/// identically named user id. Invalid entries do not enter the model menu.
pub async fn load_cetas_profiles(
  fs : &@workspace.WorkspaceFs,
  home~ : String,
  cwd~ : String,
) -> Array[@profiles.ProfileManifest] {
  let catalog : Array[@profiles.ProfileManifest] = []
  for dir in [home + "/.cetas/profiles", cwd + "/.cetas/profiles"] {
    let exists = fs.exists(dir) catch { _ => false }
    if !exists {
      continue
    }
    let files = fs.readdir(dir, include_hidden=false) catch { _ => [] }
    for file in files {
      if !file.has_suffix(".json") || file.contains("/") || file.contains("\\") {
        continue
      }
      let contents = match @workspace.read_file_result(fs, dir + "/" + file) {
        @workspace.FileReadResult::Content(text) => text
        _ => continue
      }
      let json = @json.parse(contents) catch { _ => continue }
      let profile = match @profiles.parse_profile_manifest(json) {
        Ok(value) => value
        Err(_) => continue
      }
      // id and filename must match to keep file-level provenance predictable.
      if file != profile.id + ".json" {
        continue
      }
      let mut found = false
      for i, existing in catalog {
        if existing.id == profile.id {
          catalog[i] = profile
          found = true
          break
        }
      }
      if !found {
        catalog.push(profile)
      }
    }
  }
  catalog
}
