///|
/// Provider ids become a credential filename: only a bare path segment may
/// reach the store, so traversal never addresses a file outside
/// `<credentials>`.
test "provider ids stay one path segment" {
  assert_true(provider_id_is_valid("openai"))
  assert_true(provider_id_is_valid("opencode-zen"))
  assert_false(provider_id_is_valid(""))
  assert_false(provider_id_is_valid("."))
  assert_false(provider_id_is_valid(".."))
  assert_false(provider_id_is_valid("../settings"))
  assert_false(provider_id_is_valid("nested/openai"))
  assert_false(provider_id_is_valid("nested\\openai"))
}

///|
/// A failed sign-in keeps the shape the success JSON has, so a host parses one
/// envelope: `type` decides, `structured` always names the provider.
test "login failure keeps the login envelope" {
  let expected =
    #|{"type":"error","error":"no registered API-key provider","structured":{"provider":"openai","method":"api_key"}}
  inspect(
    login_failure_json("openai", "api_key", "no registered API-key provider"),
    content=expected,
  )
}

///|
/// Logout distinguishes "signed out" from "was not signed in", and both are
/// successes.
test "logout outcome reports whether a record was removed" {
  let removed =
    #|{"type":"success","feedback":"Logged out of openai","structured":{"provider":"openai","removed":true}}
  let absent =
    #|{"type":"success","feedback":"No stored credential for openai","structured":{"provider":"openai","removed":false}}
  let failed =
    #|{"type":"error","error":"cannot delete the stored credential","structured":{"provider":"openai","removed":false}}
  inspect(logout_outcome_json("openai", true), content=removed)
  inspect(logout_outcome_json("openai", false), content=absent)
  inspect(
    logout_failure_json("openai", "cannot delete the stored credential"),
    content=failed,
  )
}

///|
/// `<Provider> / <model>` slot labels are the registry's own display names.
test "provider titles come from namespaced slot labels" {
  inspect(provider_label_title("Kimi / kimi-k2"), content="Kimi")
  inspect(provider_label_title("OpenAI / gpt-5"), content="OpenAI")
  inspect(provider_label_title("gpt-5"), content="")
  inspect(provider_label_title(" / bare"), content="")
}

///|
/// The inventory is enumerated from the registries `login` resolves against: no
/// hardcoded provider list, one row per id, methods deduped and always ordered
/// `api_key` before `oauth`.
test "provider inventory enumerates the registries" {
  let rows = provider_inventory(Map::from_array([]))
  assert_true(rows.length() > 0)
  let seen : Map[String, Unit] = Map::from_array([])
  for row in rows {
    let (provider_id, methods) = row
    assert_true(provider_id_is_valid(provider_id))
    assert_false(seen.contains(provider_id))
    seen[provider_id] = ()
    assert_false(methods.is_empty())
    for auth_method in methods {
      assert_true(auth_method == "api_key" || auth_method == "oauth")
    }
    if methods.length() == 2 {
      inspect(methods[0], content="api_key")
      inspect(methods[1], content="oauth")
    }
  }
  // Providers registered for both seams appear once, with both methods.
  let both : Array[String] = []
  for row in rows {
    if row.1.length() == 2 {
      both.push(row.0)
    }
  }
  assert_true(both.contains("kimi"))
  assert_true(both.contains("openai"))
}

///|
/// Settings-derived OpenAI-compatible ids join the inventory exactly as they
/// join `login`, and a settings-shaped custom id never collides with a static
/// provider.
test "provider inventory includes settings-derived providers" {
  let custom : Json = Json::object(
    Map::from_array([
      ("model", Json::string("qwen-max")),
      ("base_url", Json::string("https://example.invalid/v1")),
    ]),
  )
  let settings : Map[String, Json] = Map::from_array([("my-gateway", custom)])
  let rows = provider_inventory(settings)
  let mut found = false
  for row in rows {
    if row.0 == "my-gateway" {
      found = true
      inspect(row.1[0], content="api_key")
    }
  }
  assert_true(found)
}

///|
/// The exact wire row: the four field names a GUI binds to, with `methods`
/// already in registry order.
test "provider row keeps the documented shape" {
  let row = provider_row_json("kimi", "Kimi", true, ["api_key", "oauth"])
  let expected =
    #|{"id":"kimi","name":"Kimi","signed_in":true,"methods":["api_key","oauth"]}
  inspect(row.stringify(), content=expected)
  let unsigned = provider_row_json("deepseek", "deepseek", false, ["api_key"])
  let expected_unsigned =
    #|{"id":"deepseek","name":"deepseek","signed_in":false,"methods":["api_key"]}
  inspect(unsigned.stringify(), content=expected_unsigned)
}
