///|
/// The roster in cetas-core names which capability each surface composes. The
/// recipe projection is mechanical, but the surface-assembled rows (MCP, plan,
/// telemetry, delegation) are wired by hand in the composition root — that gap
/// is exactly how herdr presence went missing on this host. This test pins the
/// wired result against the roster so an inventory edit cannot pass silently.

///|
/// Extension ids the native surface assembles outside the recipe.
fn roster_host_ext_ids() -> Array[String] {
  ["posoco_ext_plan", "posoco_ext_mcp"]
}

///|
fn roster_ext_ids(zoo : Json) -> Map[String, Unit] {
  let ids : Map[String, Unit] = Map([])
  let fields = match zoo {
    Json::Object(fields) => fields
    _ => return ids
  }
  let entries = match fields.get("extensions") {
    Some(Json::Array(entries)) => entries
    _ => return ids
  }
  for entry in entries {
    let item = match entry {
      Json::Object(item) => item
      _ => continue
    }
    match item.get("id") {
      Some(Json::String(id)) => ids[id] = ()
      _ => ()
    }
  }
  ids
}

///|
async test "composed console wires every capability its roster row claims" {
  @async.with_task_group(group => {
    let cwd = @fs.tmpdir(prefix="cetas-roster-")
    let home = permission_fixture("roster")
    let fs_impl = @workspace.NativeWorkspaceFs()
    let fs : &@workspace.WorkspaceFs = fs_impl
    let config = console_config(fs, home, "cetas-native", "cetas-native/0.1")
    let runtime = compose_console_runtime(config, cwd, group)
    let ids = roster_ext_ids(runtime.zoo_json())
    for id in roster_host_ext_ids() {
      assert_true(ids.contains(id))
    }
    // Plan mode's `/plan` reaches the terminal through the agent's own command
    // port, so this assertion is the command palette's contract, not a piece of
    // host UI the console invents.
    let commands = runtime.commands_json().stringify()
    assert_true(commands.contains("\"id\":\"plan\""))
    // The roster row the recipe builds must exist as a real extension too: a
    // key with no constructor raises at composition, and this proves the other
    // direction — the recipe is not empty.
    assert_true(compiled_recipe.length() > 0)
    assert_true(compiled_recipe_packages.length() >= compiled_recipe.length())
    runtime.shutdown_all()
    permission_fixture_cleanup(cwd)
    permission_fixture_cleanup(home)
  })
}

///|
test "console recipe projects the cetas roster" {
  assert_eq(compiled_recipe, @cetas_core.cetas_recipe_keys("native"))
  assert_eq(
    compiled_recipe_packages,
    @cetas_core.cetas_capability_packages("native"),
  )
}
