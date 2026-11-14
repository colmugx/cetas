///|
/// A clean Cetas home has no authored manifests, but Profiles must still
/// register /profiles and /profile save on the first Agent composition.
async test "Profiles commands exist on a fresh Cetas installation" {
  let fs = FakeFs()
  let exts = build_compiled_recipe_features(ctx={
    fs,
    cwd: "/workspace",
    home: "/home/test",
  })
  let profiles = match
    exts.iter().find_first(ext => ext.extension_id() == "posoco_ext_profiles") {
    Some(ext) => ext
    None => fail("Profiles must be registered before the first manifest")
  }
  let commands = profiles.manifest().commands
  let names : Array[String] = []
  for command in commands {
    for def in command.commands() {
      names.push(def.id)
    }
  }
  assert_true(names.contains("profiles"))
  assert_true(names.contains("profile"))
}

///|
/// Saving through CetasProfileStore and reloading through the exact Cetas
/// catalog loader must share one format. The project entry takes priority
/// over the user entry with the same id.
async test "Profiles catalog reloads durable saves and project overrides user" {
  let fs = FakeFs()
  let name = "research"
  let user = @profiles.parse_profile_manifest({
    "id": name,
    "name": "User Research",
    "description": "General web research",
    "exts": ["posoco_ext_webfetch"],
  }).unwrap()
  let project = @profiles.parse_profile_manifest({
    "id": name,
    "name": "Project Research",
    "description": "Research with project sources",
    "exts": ["posoco_ext_webfetch", "posoco_ext_skills"],
  }).unwrap()
  let store = @cetas_core.CetasProfileStore(
    fs,
    home="/home/test",
    cwd="/workspace",
  )
  assert_true(store.write("user", user) is Ok(_))
  assert_true(fs.files.contains("/home/test/.cetas/profiles/research.json"))
  let first = @cetas_core.load_cetas_profiles(
    fs,
    home="/home/test",
    cwd="/workspace",
  )
  assert_eq(first.length(), 1)
  assert_eq(first[0].name, "User Research")
  assert_true(store.write("project", project) is Ok(_))
  let loaded = @cetas_core.load_cetas_profiles(
    fs,
    home="/home/test",
    cwd="/workspace",
  )
  assert_eq(loaded.length(), 1)
  assert_eq(loaded[0].name, "Project Research")
  assert_eq(loaded[0].exts.length(), 2)
  assert_true(store.write("invalid", user) is Err(_))
}
