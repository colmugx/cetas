///|
// managed by generate_my_extensions.mbtx — `on` / `off` rewrite this file;
// to customize, edit real_template in the script, not this file.
// Plugs @nmem (Nowledge Mem), @obsidian and @zcode into cetas-js.
// The seams live in cetas-js/lib/recipe.mbt:
//   - build_compiled_recipe_features calls append_my_extensions just
//     before the LazyTools wrapping
//   - build_compiled_zcode_ext delegates to my_zcode_ext
fn append_my_extensions(
  nmem_group : @async.TaskGroup[Unit]?,
  obsidian_vault : String?,
  episodic : Array[&@posoco.Extension],
) -> Unit {
  // Nowledge Mem
  let memory = @nmem.NowledgeMem(
    source_app="cetas",
    transport=@nmem.HttpNmemTransport::HttpNmemTransport()
      as &@nmem.NmemTransport,
    mcp=@nmem.LazyNmemMcp::LazyNmemMcp() as &@nmem.NmemMcp,
    platform=@nmem.PlatformFs::PlatformFs() as &@nmem.NmemPlatform,
  )
  match nmem_group {
    Some(group) => memory.attach(group)
    None => ()
  }
  episodic.push(memory as &@posoco.Extension)

  // Obsidian
  let vault : String? = match obsidian_vault {
    Some(name) => Some(name)
    None =>
      match @env.get_env_var("CETAS_OBSIDIAN") {
        Some(value) if value != "on" && value != "1" && value != "off" =>
          Some(value)
        _ => None
      }
  }
  episodic.push(
    @obsidian.ObsidianTools::new(
      config=@obsidian.ObsidianConfig::ObsidianConfig(vault~, read_only=false),
    )
    as &@posoco.Extension,
  )
}

///|
// Called from the existing build_compiled_zcode_ext() in recipe.mbt.
async fn zcode_ext(
  env~ : (String) -> String?,
  exists~ : async (String) -> Bool,
) -> &@posoco.Extension? {
  let detected = @zcode.zcode_ext_if_detected(env~, exists~) catch { _ => None }
  match detected {
    Some(ext) => Some(ext as &@posoco.Extension)
    None => None
  }
}
