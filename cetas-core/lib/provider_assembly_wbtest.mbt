///|
test "valid_provider_id accepts only filesystem-safe ids" {
  assert_true(valid_provider_id("deepseek"))
  assert_true(valid_provider_id("my-provider_2"))
  assert_false(valid_provider_id(""))
  assert_false(valid_provider_id("../evil"))
  assert_false(valid_provider_id("a/b"))
  assert_false(valid_provider_id("a.b"))
  assert_false(valid_provider_id("a b"))
}

///|
test "validate_provider_settings rejects traversal-shaped keys" {
  let settings : Map[String, Json] = Map::from_array([
    ("../evil", Json::object(Map::from_array([]))),
  ])
  try validate_provider_settings(settings, []) catch {
    @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
      assert_true(detail.contains("not a valid provider id"))
    _ => fail("expected traversal-shaped provider id to be rejected")
  } noraise {
    _ => fail("expected traversal-shaped provider id to be rejected")
  }
}

///|
async test "compatible_provider_factories never mints invalid ids" {
  let ctx = @devkit.ExtContext::default()
  let settings : Map[String, Json] = Map::from_array([
    ("../evil", Json::object(Map::from_array([]))),
    ("a/b", Json::object(Map::from_array([]))),
    ("custom-ok", Json::object(Map::from_array([]))),
  ])
  let factories = compatible_provider_factories(settings, ctx)
  inspect(factories.length(), content="1")
}

///|
test "parse_refresh_provider_ids validates id shape" {
  try parse_refresh_provider_ids("[\"../evil\"]") catch {
    @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
      assert_true(detail.contains("letters, digits"))
    _ => fail("expected traversal-shaped refresh id to be rejected")
  } noraise {
    _ => fail("expected traversal-shaped refresh id to be rejected")
  }
  match parse_refresh_provider_ids("") {
    None => ()
    Some(_) => fail("empty selector means all providers (None)")
  }
}
