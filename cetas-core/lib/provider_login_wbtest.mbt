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
test "typesafe resolves api_key login and the jev id stays unregistered" {
  // `/login typesafe` reaches the api_key flow without a method argument.
  assert_eq(resolve_login_method("typesafe", ""), "api_key")
  // The provider id is fixed to typesafe: `/login jev` has no factory.
  let jev = Ok(resolve_login_method("jev", "")) catch { err => Err(err) }
  match jev {
    Err(@posoco.CommandError::ExecutionFailed(message)) =>
      assert_true(message.contains("no registered authentication provider"))
    _ => fail("the legacy jev id must not resolve a login method")
  }
  // Setup discovery advertises typesafe with exactly the api_key method.
  let json = @json.parse(provider_setup_json([]))
  guard json is Json::Object(fields) else {
    fail("setup json must be an object")
  }
  guard fields.get("authProviders") is Some(Json::Array(entries)) else {
    fail("authProviders must be an array")
  }
  let mut found = false
  for entry in entries {
    if entry
      is Json::Object(
        {
          "provider": Json::String("typesafe"),
          "methods": Json::Array(methods),
          ..
        }
      ) {
      found = true
      assert_eq(methods, [Json::string("api_key")])
    }
  }
  assert_true(found)
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
test "factory registry exposes the nine registered providers in order" {
  let ctx = @devkit.ExtContext::default()
  let factories = provider_factories(ctx)
  assert_eq(factories.length(), 9)
  assert_eq(factories[0].provider_id(), "deepseek")
  assert_eq(factories[1].provider_id(), "kimi")
  assert_eq(factories[2].provider_id(), "openai")
  assert_eq(factories[3].provider_id(), "opencode")
  assert_eq(factories[4].provider_id(), "opencode-go")
  assert_eq(factories[5].provider_id(), "zai")
  assert_eq(factories[6].provider_id(), "zai-coding-plan")
  assert_eq(factories[7].provider_id(), "openrouter")
  assert_eq(factories[8].provider_id(), "typesafe")
}

///|
test "oauth factory registry carries device_id through to kimi" {
  let ctx = @devkit.ExtContext::default()
  let factories = oauth_factories(ctx, device_id="test-device-id")
  // Kimi, OpenAI/Codex, and OpenCode Go expose OAuth.
  assert_eq(factories.length(), 3)
  assert_eq(factories[0].provider_id(), "kimi")
  assert_eq(factories[1].provider_id(), "openai")
  assert_eq(factories[2].provider_id(), "opencode-go")
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

///|
test "settings-derived custom provider resolves api_key login and joins the setup auth matrix" {
  let settings : Map[String, Json] = Map::from_array([
    ("qwen", Json::object(Map::from_array([]))),
  ])
  // A custom id claimed by no static provider is served by an
  // openai-compatible instance, which exposes exactly api_key login.
  assert_eq(resolve_login_method("qwen", "", settings~), "api_key")
  // Without settings the same id remains unknown and fails fast.
  let unknown = Ok(resolve_login_method("qwen", "")) catch { err => Err(err) }
  match unknown {
    Err(@posoco.CommandError::ExecutionFailed(message)) =>
      assert_true(message.contains("no registered authentication provider"))
    _ => fail("a custom id without settings must not resolve a method")
  }
  // The settings-aware factory list validates the custom id, so "qwen": {}
  // no longer fails composition.
  let ctx = @devkit.ExtContext::default()
  validate_provider_settings(settings, all_provider_factories(ctx, settings))
  // The setup auth matrix advertises the custom id's api_key method so
  // `/login qwen` is reachable before any credential exists.
  let json = @json.parse(provider_setup_json([], settings~))
  guard json is Json::Object(fields) else {
    fail("setup json must be an object")
  }
  guard fields.get("authProviders") is Some(Json::Array(entries)) else {
    fail("authProviders must be an array")
  }
  let mut found = false
  for entry in entries {
    if entry
      is Json::Object(
        {
          "provider": Json::String("qwen"),
          "methods": Json::Array(methods),
          ..
        }
      ) {
      found = true
      assert_eq(methods, [Json::string("api_key")])
    }
  }
  assert_true(found)
}

///|
/// A factory whose build always fails, standing in for a misconfigured
/// provider. Used to pin the isolation seam: one bad provider must yield a
/// recorded issue, never a fatal composition error.
struct WbBrokenFactory {}

///|
fn WbBrokenFactory::WbBrokenFactory() -> WbBrokenFactory {
  WbBrokenFactory::{ }
}

///|
pub impl @llm.ProviderFactory for WbBrokenFactory with fn provider_id(
  _self : WbBrokenFactory,
) -> String {
  "wb-broken"
}

///|
pub extend WbBrokenFactory with @posoco/ext-llm.ProviderFactory::{
  credential_id,
  provider_id,
  build,
}

///|
pub impl @llm.ProviderFactory for WbBrokenFactory with fn credential_id(
  _self : WbBrokenFactory,
) -> String {
  "wb-broken"
}

///|
pub impl @llm.ProviderFactory for WbBrokenFactory with fn build(
  _self : WbBrokenFactory,
  _source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  raise @posoco.CompositionError::ManifestSchemaError(
    manifest_id="wb_broken",
    detail="boom",
  )
}

///|
test "try_build_provider_catalog isolates a failing factory" {
  let broken : WbBrokenFactory = WbBrokenFactory()
  let factory : &@llm.ProviderFactory = broken
  let snapshot = ProviderCredentialSnapshot::ProviderCredentialSnapshot()
  match try_build_provider_catalog(factory, snapshot) {
    Err(@posoco.CompositionError::ManifestSchemaError(manifest_id~, ..)) =>
      assert_eq(manifest_id, "wb_broken")
    _ => fail("a failing factory must surface Err, not escape as a raise")
  }
}

///|
test "provider_setup_json carries isolated build issues as warnings" {
  let issues = [
    {
      provider_id: "wb-broken",
      detail: "CompositionError::ManifestSchemaError(manifest=wb_broken)",
    },
  ]
  let json_text = provider_setup_json([], issues~)
  let parsed = @json.parse(json_text) catch {
    _ => fail("setup json must parse")
  }
  guard parsed is Object(root) else { fail("setup json must be an object") }
  match root.get("warnings") {
    Some(Array(entries)) if entries.length() == 1 => {
      guard entries[0] is String(warning) else {
        fail("warning entry must be a string")
      }
      assert_true(warning.contains("wb-broken"))
      assert_true(warning.contains("skipped"))
    }
    _ => fail("issues must be surfaced as a warnings array")
  }
}

///|
/// Count entries flagged active and read the echoed activeModelId field.
fn active_entries(json_str : String) -> (Int32, String?) raise {
  let json = @json.parse(json_str)
  guard json is Object(fields) else { fail("setup json must be an object") }
  guard fields.get("providers") is Some(Array(entries)) else {
    fail("providers must be an array")
  }
  let mut count = 0
  for entry in entries {
    guard entry is Object(entry_fields) else { fail("entry must be an object") }
    if entry_fields.get("active") is Some(True) {
      count = count + 1
    }
  }
  let active_model_id = match fields.get("activeModelId") {
    Some(String(value)) => Some(value)
    _ => None
  }
  (count, active_model_id)
}

///|
test "provider_setup_json flags exactly the selected slot and echoes activeModelId" {
  let catalogs = [tk_catalog([tk_slot("a/one"), tk_slot("b/two")])]
  let (count, echoed) = active_entries(
    provider_setup_json(catalogs, active_model_id=Some("b/two")),
  )
  assert_eq(count, 1)
  assert_eq(echoed, Some("b/two"))
}

///|
test "provider_setup_json keeps a pending selection visible without flagging any slot" {
  let catalogs = [tk_catalog([tk_slot("a/one")])]
  let (count, echoed) = active_entries(
    provider_setup_json(catalogs, active_model_id=Some("gone/slot")),
  )
  assert_eq(count, 0)
  assert_eq(echoed, Some("gone/slot"))
}

///|
test "provider_setup_json without a selection marks nothing active" {
  let catalogs = [tk_catalog([tk_slot("a/one"), tk_slot("b/two")])]
  let (count, echoed) = active_entries(provider_setup_json(catalogs))
  assert_eq(count, 0)
  assert_eq(echoed, None)
}

///|
priv struct TypesafeScriptedPrompt {
  response : String
}

///|
impl @oauth.AuthPromptInteraction for TypesafeScriptedPrompt with fn prompt(
  self : TypesafeScriptedPrompt,
  _request : @oauth.AuthPromptRequest,
) -> String raise @oauth.OAuthError {
  self.response
}

///|
async test "login_provider runs the typesafe api_key flow end to end" {
  let outcome = login_provider(
    "typesafe",
    "",
    @oauth.NoopAuthInteraction::NoopAuthInteraction() as &@oauth.AuthInteraction,
    TypesafeScriptedPrompt::{ response: "sk-jev-key", }
    as &@oauth.AuthPromptInteraction,
  )
  assert_eq(outcome.provider_id, "typesafe")
  assert_eq(outcome.login_method, "api_key")
  assert_true(outcome.credential is @oauth.ProviderCredential::ApiKey(_))
}

///|
async test "login_provider reports a failed typesafe login explicitly" {
  let outcome = Ok(
    login_provider(
      "typesafe",
      "",
      @oauth.NoopAuthInteraction::NoopAuthInteraction()
      as &@oauth.AuthInteraction,
      TypesafeScriptedPrompt::{ response: "  ", }
      as &@oauth.AuthPromptInteraction,
    ),
  ) catch {
    err => Err(err)
  }
  match outcome {
    Err(@posoco.CommandError::ExecutionFailed(message)) => {
      assert_true(message.contains("API-key login failed for typesafe"))
      assert_true(message.contains("must not be empty"))
    }
    _ => fail("an empty typesafe key must fail the login explicitly")
  }
}

///|
test "provider_setup_json exposes the slot kind on every entry" {
  let catalogs = [tk_catalog([tk_slot("a/one"), tk_decision_slot("a/judge")])]
  let json = @json.parse(provider_setup_json(catalogs)) catch {
    _ => fail("setup json must parse")
  }
  guard json is Json::Object(fields) else {
    fail("setup json must be an object")
  }
  guard fields.get("providers") is Some(Json::Array(entries)) else {
    fail("providers must be an array")
  }
  assert_eq(entries.length(), 2)
  guard entries[0] is Json::Object(chat) else {
    fail("entry must be an object")
  }
  // Absent-from-JSON kinds read as chat, and the wire id says so.
  assert_eq(chat.get("kind"), Some(Json::string("chat")))
  guard entries[1] is Json::Object(decision) else {
    fail("entry must be an object")
  }
  assert_eq(decision.get("kind"), Some(Json::string("decision")))
}
