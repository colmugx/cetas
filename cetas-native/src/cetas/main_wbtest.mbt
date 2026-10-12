///|
test "native startup permission posture matches Cetas hosts" {
  let (default_mode, default_warning) = startup_permission_mode(None)
  assert_true(default_mode is @permission.Yolo)
  assert_true(default_warning is None)

  let (read_only_mode, read_only_warning) = startup_permission_mode(
    Some("readonly"),
  )
  assert_true(read_only_mode is @permission.ReadOnly)
  assert_true(read_only_warning is None)

  let (workspace, workspace_warning) = startup_permission_mode(
    Some("workspace_write"),
  )
  assert_true(workspace is @permission.WorkspaceWrite)
  assert_true(workspace_warning is None)

  let (interactive, interactive_warning) = startup_permission_mode(
    Some("interactive"),
  )
  assert_true(interactive is @permission.Interactive)
  assert_true(interactive_warning is None)

  let (yolo, yolo_warning) = startup_permission_mode(Some("yolo"))
  assert_true(yolo is @permission.Yolo)
  assert_true(yolo_warning is None)

  let (fallback, warning) = startup_permission_mode(Some("typo"))
  assert_true(fallback is @permission.WorkspaceWrite)
  assert_true(warning is Some(_))
}
