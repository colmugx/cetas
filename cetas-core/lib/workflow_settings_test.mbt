///|
test "workflow feature defaults disabled with bounded shared budgets" {
  let settings = @lib.workflow_settings_from_json("{}")
  assert_false(settings.enabled)
  assert_eq(settings.max_executions, 8)
  assert_eq(settings.max_elapsed_ms, 600000)
  assert_eq(settings.execution_timeout_ms, 60000)
  assert_eq(settings.max_concurrency, 2)
  assert_eq(settings.max_expansions, 2)
  assert_eq(settings.max_generated_tasks, 20)
  assert_eq(settings.max_depth, 16)
  assert_false(settings.continue_on_confirmed_failure)
}

///|
test "public workflow contract tolerates settings BOM and unrelated provider keys" {
  let settings = @lib.workflow_settings_from_json(
    "\uFEFF{\"providers\":{\"kimi\":{}},\"workflow\":{\"enabled\":true,\"max_expansions\":3}}",
  )
  assert_true(settings.enabled)
  assert_eq(settings.max_expansions, 3)
  assert_eq(settings.max_executions, 8)
}

///|
test "workflow settings fail composition loudly" {
  for text in ["{broken", "{\"workflow\":{\"unknown\":1}}"] {
    try @lib.workflow_settings_from_json(text) catch {
      error => assert_true(error.to_string().contains("cetas.workflow"))
    } noraise {
      _ => fail("expected invalid workflow settings to fail")
    }
  }
}
