///|
test "an equipped session prompt never claims tools are missing" {
  let prompt = memoh_system_prompt("")
  assert_true(prompt.contains("Use Memoh Tools for"))
  assert_false(prompt.contains("no Memoh Tools access"))
}

///|
test "a degraded session states the loss instead of inviting invented actions" {
  let prompt = memoh_system_prompt(
    "No Memoh Tools gateway was declared for this session.",
  )
  assert_true(
    prompt.contains("No Memoh Tools gateway was declared for this session."),
  )
  assert_true(prompt.contains("no Memoh Tools access"))
  assert_true(prompt.contains("do not claim to have read"))
}

///|
test "clipped bounds third-party detail without touching short text" {
  assert_eq(clipped("ok", 8), "ok")
  let long = "x".repeat(40)
  let bounded = clipped(long, 8)
  assert_eq(bounded.length(), 8 + "...(truncated)".length())
  assert_true(bounded.has_prefix("xxxxxxxx"))
}
