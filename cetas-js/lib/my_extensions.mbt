///|
// managed by generate_my_extensions.mbtx — `on` / `off` rewrite this file.
// UNPLUGGED stub: same seams as the real variant, no extension bodies.
fn append_my_extensions(
  nmem_group : @async.TaskGroup[Unit]?,
  obsidian_vault : String?,
  episodic : Array[&@posoco.Extension],
) -> Unit {
  let _ = nmem_group
  let _ = obsidian_vault
  let _ = episodic
}

///|
// Called from the existing build_compiled_zcode_ext() in recipe.mbt.
async fn zcode_ext(
  env~ : (String) -> String?,
  exists~ : async (String) -> Bool,
) -> &@posoco.Extension? {
  let _ = env
  let _ = exists
  None
}