///|
test "Memoh login candidates use only registered provider capabilities" {
  let choices = memoh_login_candidates(Map::from_array([]))
  let ids = choices.map(fn(value) { value.id })
  assert_true(ids.contains("openai"))
  assert_true(ids.contains("kimi"))
  assert_true(ids.contains("deepseek"))
  assert_true(ids.contains("zai"))
  for option in choices {
    assert_true(option.methods.contains("api_key") || option.methods.contains("oauth"))
    if option.id == "kimi" || option.id == "openai" {
      assert_true(option.methods.contains("oauth"))
      assert_true(option.methods.contains("api_key"))
    }
  }
  let custom = memoh_login_candidates(
    Map::from_array([("my_provider", Json::object(Map::from_array([])))]),
  )
  assert_true(custom.any(fn(option) {
    option.id == "my_provider" && option.methods.contains("api_key")
  }))
}
