///|
/// JavaScript-only extension seam. This file is deliberately dependency-free:
/// public CI never needs private MoonBit packages. In your private branch,
/// edit this file and add imports to cetas-js/moon.mod and lib/moon.pkg.
/// See cetas-js/PRIVATE_EXTENSIONS.md.
///
/// Nowledge Mem and Obsidian belong in `episodic` (before LazyTools wrapping);
/// ordinary eager tools belong in `exts`.
async fn append_private_recipe_features(
  ctx~ : @cetas_core.HostContext,
  nmem_group : @async.TaskGroup[Unit]?,
  obsidian_vault : String?,
  exts : Array[&@posoco.Extension],
  episodic : Array[&@posoco.Extension],
) -> Unit {
  let _ = ctx
  let _ = nmem_group
  let _ = obsidian_vault
  let _ = exts
  let _ = episodic
}

///|
/// Optional Zcode detection is invoked by the JS parent agent only.
/// Override this stub in your private branch. Do not register Zcode as
/// an episodic extension above; it owns its own detection and lifecycle.
async fn build_compiled_zcode_ext(
  env~ : (String) -> String?,
  exists~ : async (String) -> Bool,
) -> &@posoco.Extension? {
  let _ = env
  let _ = exists
  None
}
