///|
/// The standard public Run composition is the executable-side projection of
/// the shared Cetas roster. Concrete adapters are host-owned, while their
/// product semantics remain in cetas-core.
async test "public run recipe assembles the standard Cetas capabilities" {
  let fs = FakeFs()
  let exts = build_compiled_recipe_features(ctx={
    fs,
    cwd: "/repo",
    home: "/home/u",
  })
  assert_eq(exts.length(), 13)
  let ids : Array[String] = []
  for ext in exts {
    ids.push(ext.extension_id())
  }
  assert_true(ids.contains("forme"))
  assert_true(ids.contains("posoco_ext_skills"))
  assert_true(ids.contains("posoco_ext_webfetch"))
  assert_true(ids.contains("posoco_ext_lazytools"))
  assert_false(ids.contains("posoco_ext_nowledge_mem"))
  assert_false(ids.contains("posoco_ext_obsidian"))
}

///|
test "public run shell capability canonicalizes by compiled platform" {
  assert_eq(canonical_cetas_tool_name("read"), "read")
  if compiled_target_os() == "windows" {
    assert_eq(canonical_cetas_tool_name("bash"), "ps1")
  } else {
    assert_eq(canonical_cetas_tool_name("bash"), "bash")
  }
}
