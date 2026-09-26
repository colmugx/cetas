///|
/// Cetas-Memoh owns provider configuration and credentials independently from
/// generic Cetas. Memoh's generic ACP runtime currently launches agents with
/// HOME=/data, so the default inside a workspace is /data/.cetas-memoh.
pub fn cetas_memoh_home() -> String {
  match @env.get_env_var("CETAS_MEMOH_HOME") {
    Some(value) if !value.trim().is_empty() => value.trim().to_owned()
    _ =>
      match @env.get_env_var("HOME") {
        Some(home) if !home.trim().is_empty() =>
          home.trim().to_owned() + "/.cetas-memoh"
        _ => ".cetas-memoh"
      }
  }
}

///|
pub fn providers_path(home : String) -> String {
  home + "/providers.json"
}

///|
pub fn credentials_path(home : String) -> String {
  home + "/credentials"
}
