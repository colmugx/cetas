///|
async test "BOM settings provider and model reads and writes agree" {
  let fs = FakeFs()
  let path = "/h/.cetas/settings.json"
  fs.files[path] = "\uFEFF{\r\n\"providers\":{\"kimi\":{}},\"model\":\"old/a\",\"unknown\":1\r\n}"
  assert_true(load_provider_settings(fs, home="/h").contains("kimi"))
  match read_active_model_selection(fs, home="/h") {
    Some(selection) => assert_eq(selection.slot, "old/a")
    None => fail("expected the BOM-prefixed model selection")
  }
  write_active_model_selection(fs, home="/h", ActiveModelSelection("new/b"))
  let written = @json.parse(fs.files[path])
  json_inspect(written, content={
    "providers": { "kimi": {} },
    "model": "new/b",
    "unknown": 1,
  })
  assert_false(fs.files[path].has_prefix("\uFEFF"))
  assert_true(load_provider_settings(fs, home="/h").contains("kimi"))
  match read_active_model_selection(fs, home="/h") {
    Some(selection) => assert_eq(selection.slot, "new/b")
    None => fail("expected the updated selection")
  }
}

///|
async test "BOM does not bypass settings schemas or overwrite malformed settings" {
  let fs = FakeFs()
  let path = "/h/.cetas/settings.json"
  for text in ["\uFEFF[]", "\uFEFF{\"providers\":42}"] {
    fs.files[path] = text
    try load_provider_settings(fs, home="/h") catch {
      error => assert_true(error.to_string().contains("must be an object"))
    } noraise {
      _ => fail("expected invalid settings schema to fail")
    }
  }
  for text in ["\uFEFF[]", "\uFEFF{broken"] {
    fs.files[path] = text
    try
      write_active_model_selection(fs, home="/h", ActiveModelSelection("new/b"))
    catch {
      _ => assert_eq(fs.files[path], text)
    } noraise {
      _ => fail("expected invalid settings to remain untouched")
    }
  }
}
