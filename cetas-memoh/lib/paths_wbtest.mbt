///|
test "explicit CETAS_MEMOH_HOME wins over every other candidate" {
  assert_eq(
    resolve_memoh_home(
      explicit=Some("/custom/home"),
      workspace_mount=true,
      home=Some("/root"),
    ),
    "/custom/home",
  )
}

///|
test "the workspace mount wins over HOME inside a Memoh container" {
  // Memoh starts the ACP runtime with HOME=/data, but a shell opened in the
  // same container usually carries HOME=/root. The mount is the shared truth.
  assert_eq(
    resolve_memoh_home(explicit=None, workspace_mount=true, home=Some("/root")),
    "/data/.cetas-memoh",
  )
}

///|
test "HOME is used only when there is no workspace mount" {
  assert_eq(
    resolve_memoh_home(
      explicit=None,
      workspace_mount=false,
      home=Some("/home/dev"),
    ),
    "/home/dev/.cetas-memoh",
  )
}

///|
test "a blank or absent HOME falls back to a relative home" {
  assert_eq(
    resolve_memoh_home(explicit=None, workspace_mount=false, home=Some("   ")),
    ".cetas-memoh",
  )
  assert_eq(
    resolve_memoh_home(explicit=None, workspace_mount=false, home=None),
    ".cetas-memoh",
  )
}
