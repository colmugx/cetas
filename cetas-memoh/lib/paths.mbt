///|
/// Memoh's workspace mount. The generic ACP runtime starts every agent with
/// HOME=/data, so this is the durable volume provider state belongs on.
const MEMOH_WORKSPACE_MOUNT : String = "/data"

///|
/// Cetas-Memoh owns provider configuration and credentials independently from
/// generic Cetas.
///
/// Resolution order:
///
/// 1. `CETAS_MEMOH_HOME` — an explicit answer always wins.
/// 2. `<workspace mount>/.cetas-memoh` when the mount exists. Memoh starts the
///    ACP runtime with HOME=/data, while a shell opened in the same container
///    usually carries HOME=/root, so resolving from HOME alone sends
///    `cetas-memoh setup` output where the runtime never looks.
/// 3. `$HOME/.cetas-memoh`.
/// 4. `.cetas-memoh` as the last resort.
pub async fn cetas_memoh_home() -> String {
  resolve_memoh_home(
    explicit=explicit_memoh_home(),
    workspace_mount=workspace_mount_present(),
    home=@env.get_env_var("HOME"),
  )
}

///|
fn explicit_memoh_home() -> String? {
  match @env.get_env_var("CETAS_MEMOH_HOME") {
    Some(value) if !value.trim().is_empty() => Some(value.trim().to_owned())
    _ => None
  }
}

///|
/// A missing or unreadable mount simply means "not this container".
async fn workspace_mount_present() -> Bool {
  let present : Bool? = Some(@fs.exists(MEMOH_WORKSPACE_MOUNT)) catch {
    _ => None
  }
  present is Some(true)
}

///|
/// Pure resolution step so the precedence is testable without a real
/// workspace mount or a mutated process environment.
fn resolve_memoh_home(
  explicit~ : String?,
  workspace_mount~ : Bool,
  home~ : String?,
) -> String {
  match explicit {
    Some(value) => value
    None =>
      if workspace_mount {
        MEMOH_WORKSPACE_MOUNT + "/.cetas-memoh"
      } else {
        match home {
          Some(value) if !value.trim().is_empty() =>
            value.trim().to_owned() + "/.cetas-memoh"
          _ => ".cetas-memoh"
        }
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
