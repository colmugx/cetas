///|
test "settings JSON accepts BOM and CRLF without altering string values" {
  for prefix in ["", "\uFEFF"] {
    let json = @lib.parse_settings_json(
      prefix + "{\r\n\"value\": \"\uFEFFkept\"\r\n}",
      manifest_id="test.settings",
    )
    json_inspect(json, content={ "value": "\uFEFFkept" })
  }
}

///|
test "settings JSON remains strict and preserves parse diagnostics" {
  for
    text in [
      "", "\uFEFF", "\uFEFF{broken", "\uFEFF\uFEFF{}", " \uFEFF{}", "{} trailing",
    ] {
    let detail = try
      @json.parse(text.strip_prefix("\uFEFF").unwrap_or(text[:]))
    catch {
      error => error.to_string()
    } noraise {
      _ => fail("expected malformed JSON")
    }
    try @lib.parse_settings_json(text, manifest_id="test.settings") catch {
      error => {
        let message = error.to_string()
        assert_true(message.contains("test.settings"))
        assert_true(message.contains("is not valid JSON: "))
        assert_true(message.contains("is not valid JSON: " + detail))
      }
    } noraise {
      _ => fail("expected malformed settings to fail")
    }
  }
}
