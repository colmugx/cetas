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

///|
test "native product banner identifies Cetas model and session" {
  let text = startup_banner("openai/gpt-5", Some("high"), "cetas-123")
  assert_eq(
    text, "Cetas 0.7.0 · model openai/gpt-5 · effort high · session cetas-123",
  )
  assert_false(text.contains("preview"))
  assert_false(text.contains("cetas-native"))
}
