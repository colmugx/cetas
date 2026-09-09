///|
/// cetas_home.mbt — the single owner of where cetas durable state lives.
///
/// Product contract, aligned with the JS twin's `os.homedir()`: the cetas
/// home is the platform user home — USERPROFILE (then HOMEDRIVE+HOMEPATH)
/// on Windows, HOME elsewhere; `@devkit.home_dir` implements that chain and
/// documents why Windows deliberately ignores HOME (Git Bash/MSYS exports
/// POSIX-style paths a native process cannot use). `CETAS_HOME` overrides
/// it for tests and embedding; `"."` stays the last resort so a stripped
/// environment still composes and the provider gate fails loudly after.
///
/// Layout invariant: every ".cetas" path in the workspace derives from the
/// functions below. A `"/.cetas"` string literal anywhere else is a bug —
/// ci.yml greps for it.

///|
/// Resolve this process's cetas home: `CETAS_HOME` (non-empty) → platform
/// home (`@devkit.home_dir`) → `"."`.
pub fn cetas_home() -> String {
  match @env.get_env_var("CETAS_HOME") {
    Some(value) => {
      let trimmed = value.trim().to_owned()
      if trimmed == "" {
        platform_home_or_cwd()
      } else {
        trimmed
      }
    }
    None => platform_home_or_cwd()
  }
}

///|
fn platform_home_or_cwd() -> String {
  match @devkit.home_dir() {
    Some(home) => home
    None => "."
  }
}

///|
/// `<home>/.cetas` — the durable-state root (settings, credentials,
/// sessions, model cache, debug taps, mcp config).
pub fn cetas_dir(home : String) -> String {
  home + "/.cetas"
}

///|
pub fn settings_path(home : String) -> String {
  cetas_dir(home) + "/settings.json"
}

///|
pub fn credentials_path(home : String) -> String {
  cetas_dir(home) + "/credentials"
}

///|
pub fn model_list_cache_path(home : String) -> String {
  cetas_dir(home) + "/model_lists.json"
}

///|
/// Root handed to `@fs_session.JsonlSessionStore`; session JSONL files and
/// their companions live under it.
pub fn sessions_dir(home : String) -> String {
  cetas_dir(home) + "/sessions"
}

///|
/// Sidecar location beside the session's JSONL history; `None` when the id
/// cannot be a filename stem, so a client-supplied id cannot escape the
/// sessions directory.
pub fn sidecar_path(home : String, session_id : String) -> String? {
  match @fs_session.validate_session_id(session_id) {
    Ok(_) => Some(@fs_session.companion_path(sessions_dir(home), session_id))
    Err(_) => None
  }
}

///|
/// A trailing slash on `home` is normalized away so the path stays canonical.
pub fn mcp_config_path(home : String) -> String {
  let base = if home.has_suffix("/") {
    home[:home.length() - 1].to_owned()
  } else {
    home
  }
  cetas_dir(base) + "/mcp.json"
}

///|
pub fn debug_dir(home : String) -> String {
  cetas_dir(home) + "/debug"
}

///|
pub fn debug_wire_path(home : String, session_id : String) -> String {
  debug_dir(home) + "/" + session_id + "-wire.jsonl"
}

///|
pub fn debug_catalog_path(home : String, session_id : String) -> String {
  debug_dir(home) + "/" + session_id + "-catalog.json"
}
