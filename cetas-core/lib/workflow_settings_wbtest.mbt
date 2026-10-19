///|
fn workflow_rejects(text : String, fragment~ : String) -> Unit raise {
  let outcome = Ok(workflow_settings_from_json(text)) catch {
    error => Err(error)
  }
  match outcome {
    Err(@posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~)) => {
      assert_eq(manifest_id, "cetas.workflow")
      assert_true(detail.contains(fragment))
    }
    _ => fail("expected workflow settings rejection: " + text)
  }
}

///|
test "workflow defaults are identical for absent and empty sections" {
  let absent = workflow_settings_from_json("{}")
  let empty = workflow_settings_from_json("{\"workflow\":{}}")
  assert_false(empty.enabled)
  assert_eq(empty.max_executions, absent.max_executions)
  assert_eq(empty.max_depth, absent.max_depth)
}

///|
test "workflow accepts exact Board budget ceilings and floors" {
  let ceiling = workflow_settings_from_json(
    "{\"workflow\":{\"max_executions\":1000,\"max_elapsed_ms\":86400000,\"execution_timeout_ms\":86400000,\"max_concurrency\":8,\"max_expansions\":16,\"max_generated_tasks\":200,\"max_depth\":16}}",
  )
  assert_eq(ceiling.max_executions, 1000)
  assert_eq(ceiling.max_elapsed_ms, 86400000)
  assert_eq(ceiling.max_concurrency, 8)
  let floor = workflow_settings_from_json(
    "{\"workflow\":{\"max_executions\":1,\"max_elapsed_ms\":1,\"execution_timeout_ms\":1,\"max_concurrency\":1,\"max_expansions\":1,\"max_generated_tasks\":1,\"max_depth\":2}}",
  )
  assert_eq(floor.max_depth, 2)
  assert_eq(floor.execution_timeout_ms, 1)
  let integral = workflow_settings_from_json(
    "{\"workflow\":{\"max_executions\":8.0,\"max_elapsed_ms\":6e5}}",
  )
  assert_eq(integral.max_executions, 8)
}

///|
test "workflow rejects unknown control fields and invalid types" {
  for key in ["unknown", "directory", "model", "tools", "concurency"] {
    workflow_rejects(
      "{\"workflow\":{\"" + key + "\":1}}",
      fragment="unknown key",
    )
  }
  workflow_rejects(
    "{\"workflow\":{\"enabled\":\"yes\"}}",
    fragment="must be a boolean",
  )
  workflow_rejects(
    "{\"workflow\":{\"continue_on_confirmed_failure\":1}}",
    fragment="must be a boolean",
  )
  workflow_rejects(
    "{\"workflow\":{\"max_executions\":\"8\"}}",
    fragment="must be a number",
  )
  workflow_rejects(
    "{\"workflow\":{\"max_elapsed_ms\":null}}",
    fragment="must be a number",
  )
  for text in ["{\"workflow\":[]}", "{\"workflow\":null}"] {
    workflow_rejects(text, fragment="must be an object")
  }
  workflow_rejects("[]", fragment="must be an object")
}

///|
test "workflow rejects fractional, oversized and invalid relative budgets even while disabled" {
  workflow_rejects(
    "{\"workflow\":{\"max_executions\":8.5}}",
    fragment="whole number",
  )
  workflow_rejects(
    "{\"workflow\":{\"max_elapsed_ms\":100,\"execution_timeout_ms\":101}}",
    fragment="must not exceed",
  )
  for
    (key, value) in [
      ("max_executions", 0),
      ("max_executions", 1001),
      ("max_elapsed_ms", 86400001),
      ("execution_timeout_ms", 0),
      ("execution_timeout_ms", 86400001),
      ("max_concurrency", 0),
      ("max_concurrency", 9),
      ("max_expansions", 0),
      ("max_expansions", 17),
      ("max_generated_tasks", 0),
      ("max_generated_tasks", 201),
      ("max_depth", 1),
      ("max_depth", 17),
    ] {
    workflow_rejects(
      "{\"workflow\":{\"enabled\":false,\"" +
      key +
      "\":" +
      value.to_string() +
      "}}",
      fragment="must be between",
    )
  }
}

///|
test "workflow values remain detached from subsequent parses" {
  let first = workflow_settings_from_json(
    "{\"workflow\":{\"enabled\":true,\"max_generated_tasks\":5,\"continue_on_confirmed_failure\":true}}",
  )
  ignore(
    workflow_settings_from_json(
      "{\"workflow\":{\"enabled\":false,\"max_generated_tasks\":10}}",
    ),
  )
  assert_true(first.enabled)
  assert_true(first.continue_on_confirmed_failure)
  assert_eq(first.max_generated_tasks, 5)
}
