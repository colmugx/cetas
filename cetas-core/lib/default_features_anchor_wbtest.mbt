///|
/// White-box tests for host-side workspace anchoring: build_default_features
/// builds one WorkspaceAnchor from ctx.cwd and hands it to all six
/// file/shell tools, while the absolute root stays host-side.

///|
/// Field reader for an expected anchor: the six tool structs are pub(all),
/// so the stored option is inspected directly.
fn assert_stored_anchor(
  stored : @devkit.WorkspaceAnchor?,
  expected_root : String,
) -> Unit raise {
  match stored {
    Some(a) => assert_eq(a.root, expected_root)
    None => fail("expected the tool to store the workspace anchor")
  }
}

///|
test "anchored constructors store the shared anchor root" {
  let anchor = @devkit.WorkspaceAnchor::WorkspaceAnchor("/tmp/proj")
  let freshness = @devkit.FreshnessGuard::FreshnessGuard()
  assert_stored_anchor(
    @read.ReadTools(freshness~, anchor=Some(anchor)).anchor,
    "/tmp/proj",
  )
  assert_stored_anchor(
    @write.WriteTools(freshness~, anchor=Some(anchor)).anchor,
    "/tmp/proj",
  )
  assert_stored_anchor(
    @edit.EditTools(freshness~, anchor=Some(anchor)).anchor,
    "/tmp/proj",
  )
  assert_stored_anchor(@glob.GlobTools(anchor=Some(anchor)).anchor, "/tmp/proj")
  assert_stored_anchor(@grep.GrepTools(anchor=Some(anchor)).anchor, "/tmp/proj")
  assert_stored_anchor(
    @bash.ShellTools(anchor=Some(anchor)).anchor,
    "/tmp/proj",
  )
}

///|
test "default constructors leave the anchor unset (legacy process-cwd behavior)" {
  assert_true(@read.ReadTools().anchor is None)
  assert_true(@write.WriteTools().anchor is None)
  assert_true(@edit.EditTools().anchor is None)
  assert_true(@glob.GlobTools().anchor is None)
  assert_true(@grep.GrepTools().anchor is None)
  assert_true(@bash.ShellTools().anchor is None)
}

///|
test "anchor built from ctx.cwd preserves the root" {
  // Normalization must not swallow the launch directory.
  inspect(
    @devkit.WorkspaceAnchor::WorkspaceAnchor("/tmp/proj").root,
    content="/tmp/proj",
  )
  inspect(
    @devkit.WorkspaceAnchor::WorkspaceAnchor("/repo/sub/deep").root,
    content="/repo/sub/deep",
  )
}

///|
async test "build_default_features assembles the full set around the anchor" {
  // Reuses the SkillsCtxFs fake from default_features_wbtest.mbt (same
  // wbtest package): an empty environment keeps the set deterministic. The
  // returned trait objects cannot be downcast to the concrete tool structs,
  // so anchor storage itself is asserted above at the constructor level;
  // here we pin that the anchored assembly still registers the full set
  // (only the six file/shell tools carry the anchor; webfetch defers behind
  // the lazytools gateway and touches no workspace state).
  let fs = SkillsCtxFs::{
    files: Map::from_array([]),
    dirs: Map::from_array([]),
  }
  let exts = build_default_features(ctx={
    fs,
    cwd: "/tmp/proj",
    home: "/home/u",
  })
  assert_eq(exts.length(), 14)
}
