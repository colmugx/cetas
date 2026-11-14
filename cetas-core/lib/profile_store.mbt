///|
/// Durable per-project/user profile store over the host-injected WorkspaceFs.
/// The same directory policy is used by load_cetas_profiles().
pub struct CetasProfileStore {
  fs : &@workspace.WorkspaceFs
  home : String
  cwd : String
}

///|
pub fn CetasProfileStore::CetasProfileStore(
  fs : &@workspace.WorkspaceFs,
  home~ : String,
  cwd~ : String,
) -> CetasProfileStore {
  { fs, home, cwd, }
}

///|
pub impl @profiles.ProfileStore for CetasProfileStore with fn read_all(
  self : CetasProfileStore,
) -> Result[Array[(String, String)], String] {
  let entries : Array[(String, String)] = []
  for
    (level, dir) in [
      ("user", self.home + "/.cetas/profiles"),
      ("project", self.cwd + "/.cetas/profiles"),
    ] {
    let exists = self.fs.exists(dir) catch {
      error => return Err(error.to_string())
    }
    if !exists {
      continue
    }
    let filenames = self.fs.readdir(dir, include_hidden=false) catch {
      error => return Err(error.to_string())
    }
    for filename in filenames {
      if !filename.has_suffix(".json") ||
        filename.contains("/") ||
        filename.contains("\\") {
        continue
      }
      let text = self.fs.read_file(dir + "/" + filename) catch {
        error => return Err(error.to_string())
      }
      entries.push((level, text))
    }
  }
  Ok(entries)
}

///|
pub impl @profiles.ProfileStore for CetasProfileStore with fn write(
  self : CetasProfileStore,
  level : String,
  manifest : @profiles.ProfileManifest,
) -> Result[Unit, String] {
  let dir = match level {
    "user" => self.home + "/.cetas/profiles"
    "project" => self.cwd + "/.cetas/profiles"
    _ => return Err("invalid profile storage level: " + level)
  }
  // Persist only ids valid as filename stems. This is also validated by
  // parse_profile_manifest on the reader path.
  match @profiles.parse_profile_manifest(manifest.to_json()) {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  self.fs.mkdir(dir, recursive=true) catch {
    error => return Err(error.to_string())
  }
  self.fs.write_file_atomic(
    dir + "/" + manifest.id + ".json",
    manifest.to_json().stringify(indent=2) + "\n",
  ) catch {
    error => return Err(error.to_string())
  }
  Ok(())
}

///|
pub extend CetasProfileStore with @profiles.ProfileStore::{read_all, write}
