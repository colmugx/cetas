///|
test "provider ids used for durable filenames are path-safe" {
  assert_true(valid_provider_id("openai"))
  assert_true(valid_provider_id("my-provider_2"))
  assert_false(valid_provider_id(""))
  assert_false(valid_provider_id("../openai"))
  assert_false(valid_provider_id("a/b"))
  assert_false(valid_provider_id("a.b"))
}
