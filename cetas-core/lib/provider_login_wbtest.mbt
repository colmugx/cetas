///|
/// White-box tests for the provider-neutral login + catalog orchestration that
/// moved from cetas-js into cetas-core. These cover the pure inference,
/// validation, and JSON-assembly paths that every host now shares.

///|
test "provider login method inference is provider-neutral and fail-fast" {
  // DeepSeek exposes only API-key login: an empty requested method resolves
  // unambiguously.
  assert_eq(resolve_login_method("deepseek", ""), "api_key")
  // An explicit requested method is always honored.
  assert_eq(resolve_login_method("openai", "oauth"), "oauth")
  // Kimi exposes both OAuth and API-key: an empty method must require the
  // caller to disambiguate.
  let ambiguous = Ok(resolve_login_method("kimi", "")) catch { err => Err(err) }
  match ambiguous {
    Err(@posoco.CommandError::InvalidArgs(reason=message)) =>
      assert_true(message.contains("requires method"))
    _ => fail("an ambiguous provider must require an explicit method")
  }
}

///|
test "model refresh selector validates provider ids and deduplicates requests" {
  match parse_refresh_provider_ids("") {
    None => ()
    Some(_) => fail("an empty selector must refresh all providers")
  }
  match parse_refresh_provider_ids("[\"kimi\",\"kimi\"]") {
    Some(ids) => {
      assert_eq(ids.length(), 1)
      assert_eq(ids[0], "kimi")
    }
    None => fail("an explicit selector must remain provider-scoped")
  }
  let unknown = Ok(parse_refresh_provider_ids("[\"unknown\"]")) catch {
    err => Err(err)
  }
  match unknown {
    Err(@posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~)) => {
      ignore(manifest_id)
      assert_true(detail.contains("no registered provider extension"))
    }
    _ => fail("unknown refresh providers must fail at the composition boundary")
  }
}

///|
test "factory registry exposes the three registered providers in order" {
  let ctx = @devkit.ExtContext::default()
  let factories = provider_factories(ctx)
  assert_eq(factories.length(), 3)
  assert_eq(factories[0].provider_id(), "deepseek")
  assert_eq(factories[1].provider_id(), "kimi")
  assert_eq(factories[2].provider_id(), "openai")
}

///|
test "oauth factory registry carries device_id through to kimi" {
  let ctx = @devkit.ExtContext::default()
  let factories = oauth_factories(ctx, device_id="test-device-id")
  // Only kimi and openai expose OAuth.
  assert_eq(factories.length(), 2)
  assert_eq(factories[0].provider_id(), "kimi")
  assert_eq(factories[1].provider_id(), "openai")
}

///|
test "validate_provider_settings rejects unknown provider ids" {
  let ctx = @devkit.ExtContext::default()
  let factories = provider_factories(ctx)
  let unknown = Ok(
    validate_provider_settings(
      Map::from_array([("ghost", Json::object(Map::from_array([])))]),
      factories,
    ),
  ) catch {
    err => Err(err)
  }
  match unknown {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("ghost"))
    _ => fail("an unknown provider id must fail at the composition boundary")
  }
}

///|
test "provider_setup_json renders empty catalogs without crashing" {
  let json_str = provider_setup_json([])
  let json = @json.parse(json_str)
  match json {
    Json::Object(fields) =>
      match fields.get("providers") {
        Some(Json::Array(values)) => assert_eq(values.length(), 0)
        _ => fail("providers must be an array")
      }
    _ => fail("setup json must be an object")
  }
}
