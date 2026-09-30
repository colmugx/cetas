///|
#cfg(target="wasm")
async test "login wasm reports unsupported target with shared home and sandbox guidance" {
  let notes : Array[String] = []
  let result = try
    @lib.run_login(home="/must-not-read", provider="openai", note=fn(text) {
      notes.push(text)
    })
  catch {
    err => err.to_string()
  } noraise {
    _ => "unexpected success"
  }
  assert_true(result.contains("unsupported"))
  assert_eq(notes.length(), 1)
  assert_true(notes[0].contains("Cetas /login"))
  assert_true(notes[0].contains("shared home"))
  assert_true(notes[0].contains("sandbox"))
}
