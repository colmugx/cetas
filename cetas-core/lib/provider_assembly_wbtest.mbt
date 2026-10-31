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
/// The settings→catalog path for a custom provider whose entry declares a
/// non-default protocol: cetas stays out of the protocol vocabulary and only
/// hands the entry to the extension, which returns a ready slot.
test "a settings id with a declared protocol assembles through the custom provider" {
  let ctx = @devkit.ExtContext::default()
  let settings : Map[String, Json] = Map::from_array([
    (
      "claude-proxy",
      Json::object(
        Map::from_array([
          ("base_url", Json::string("https://example.com")),
          ("endpoint_prefix", Json::string("/v1")),
          ("api_key", Json::string("sk-ant")),
          ("protocol", Json::string("messages")),
          (
            "models",
            Json::array([
              Json::object(
                Map::from_array([
                  ("id", Json::string("claude-sonnet-5")),
                  ("context_window", Json::number(200000.0)),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    ),
  ])
  let factories = compatible_provider_factories(settings, ctx)
  assert_eq(factories.length(), 1)
  let snapshot = ProviderCredentialSnapshot::ProviderCredentialSnapshot(
    settings~,
  )
  match try_build_provider_catalog(factories[0], snapshot) {
    Ok(Some(catalog)) => {
      assert_eq(catalog.provider_id, "claude-proxy")
      assert_eq(catalog.slots().length(), 1)
      assert_eq(catalog.slots()[0].id, "claude-proxy/claude-sonnet-5")
      assert_eq(catalog.slots()[0].context_window, Some(200000))
    }
    _ => fail("expected a ready catalog for the custom provider")
  }
}

///|
/// A malformed protocol is a composition failure carried out of the extension,
/// not a silent fallback to the chat wire.
test "an unknown protocol fails the custom provider's build" {
  let ctx = @devkit.ExtContext::default()
  let settings : Map[String, Json] = Map::from_array([
    (
      "gw",
      Json::object(
        Map::from_array([
          ("base_url", Json::string("https://example.com/v1")),
          ("api_key", Json::string("sk")),
          ("model", Json::string("m")),
          ("protocol", Json::string("grpc")),
        ]),
      ),
    ),
  ])
  let factories = compatible_provider_factories(settings, ctx)
  let snapshot = ProviderCredentialSnapshot::ProviderCredentialSnapshot(
    settings~,
  )
  match try_build_provider_catalog(factories[0], snapshot) {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("unknown protocol: grpc"))
    _ => fail("expected the unknown protocol to fail composition")
  }
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
