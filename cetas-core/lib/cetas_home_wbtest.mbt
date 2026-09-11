///|
test "layout paths pin the .cetas contract" {
  inspect(settings_path("/h"), content="/h/.cetas/settings.json")
  inspect(credentials_path("/h"), content="/h/.cetas/credentials")
  inspect(model_list_cache_path("/h"), content="/h/.cetas/model_lists.json")
  inspect(sessions_dir("/h"), content="/h/.cetas/sessions")
  inspect(mcp_config_path("/h"), content="/h/.cetas/mcp.json")
  inspect(mcp_config_path("/h/"), content="/h/.cetas/mcp.json")
  inspect(debug_dir("/h"), content="/h/.cetas/debug")
  inspect(
    debug_wire_path("/h", "cetas-1"),
    content="/h/.cetas/debug/cetas-1-wire.jsonl",
  )
  inspect(
    debug_catalog_path("/h", "cetas-1"),
    content="/h/.cetas/debug/cetas-1-catalog.json",
  )
}

///|
test "sidecar_path sits beside the session JSONL history" {
  match sidecar_path("/h", "cetas-1") {
    Some(path) => inspect(path, content="/h/.cetas/sessions/cetas-1.host.json")
    None => fail("a valid id must produce a sidecar path")
  }
}

///|
test "sidecar_path rejects ids that cannot be filename stems" {
  assert_true(sidecar_path("/h", "../escape") is None)
  assert_true(sidecar_path("/h", "a/b") is None)
  assert_true(sidecar_path("/h", "") is None)
}

///|
/// The platform contract `cetas_home`'s chain rests on, pinned over injected
/// values: the resolution core is pure, so this needs no process env (the
/// former `cetas_home()` smoke test read the real environment).
test "home resolution keeps the platform contract over injected env" {
  // Unix: HOME.
  assert_eq(
    @devkit.home_dir_from_env(
      windows=false,
      home=Some("/home/u"),
      userprofile=None,
      homedrive=None,
      homepath=None,
    ),
    Some("/home/u"),
  )
  // Windows deliberately ignores HOME: USERPROFILE first ...
  assert_eq(
    @devkit.home_dir_from_env(
      windows=true,
      home=Some("/home/u"),
      userprofile=Some("C:\\Users\\u"),
      homedrive=None,
      homepath=None,
    ),
    Some("C:\\Users\\u"),
  )
  // ... then HOMEDRIVE+HOMEPATH.
  assert_eq(
    @devkit.home_dir_from_env(
      windows=true,
      home=Some("/home/u"),
      userprofile=None,
      homedrive=Some("C:"),
      homepath=Some("\\Users\\u"),
    ),
    Some("C:\\Users\\u"),
  )
  // No home at all: None (cetas_home then degrades to ".").
  assert_true(
    @devkit.home_dir_from_env(
      windows=false,
      home=None,
      userprofile=None,
      homedrive=None,
      homepath=None,
    )
    is None,
  )
}
