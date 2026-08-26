///|
test "JsUiPort wire encodes a structured render event" {
  let raw = ui_render_event_to_json({
    slot: @port.UiSlot::Status,
    key: "goal.progress",
    title: Some("Goal"),
    body: @port.UiBody::Progress(0.5),
    ttl_ms: Some(1000),
  })
  let json = @json.parse(raw)
  match json {
    Json::Object(event) => {
      assert_eq(event["type"], Json::string("ui_render"))
      match event["render"] {
        Json::Object(render) => {
          assert_eq(render["key"], Json::string("goal.progress"))
          assert_eq(render["ttl_ms"], Json::number(1000.0))
        }
        _ => fail("render must be an object")
      }
    }
    _ => fail("event must be an object")
  }
}

///|
test "JsUiPort wire decodes a correlated input response" {
  let response = decode_ui_response_event(
    "{\"type\":\"ui_response\",\"request_id\":\"ui-7\",\"response\":{\"type\":\"text\",\"text\":\"answer\"}}",
    "ui-7",
    @port.UiRequest::Input(prompt="Question", default=None),
  )
  match response {
    @port.UiResponse::Text(value) => assert_eq(value, "answer")
    _ => fail("expected text response")
  }
}

///|
test "JsUiPort wire rejects a response for another request" {
  try
    ignore(
      decode_ui_response_event(
        "{\"type\":\"ui_response\",\"request_id\":\"ui-8\",\"response\":{\"type\":\"yes\"}}",
        "ui-7",
        @port.UiRequest::Confirm(prompt="Continue?"),
      ),
    )
  catch {
    @error.UiError::InvalidRequest(detail=message) =>
      assert_eq(message, "ui_response.request_id does not match")
    _ => fail("expected UiError::HostError")
  } noraise {
    _ => fail("expected mismatched request id to fail")
  }
}

///|
/// `resolve_login_method` now lives in cetas-core; its provider-neutral
/// inference is tested there (provider_login_wbtest.mbt).

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
/// The factory registry (provider/oauth/api_key/refreshable) now lives in
/// cetas-core and is covered by provider_login_wbtest.mbt there. The JS host
/// forwards to it, so this test is no longer host-specific.

///|
/// Credential persistence (tagged record codec, file backend, atomic replace)
/// lives in posoco-ext-credentials and is covered by its white-box tests.

///|
test "CetasJsConfig empty sessions_dir falls back to the flat home root" {
  let config = CetasJsConfig::CetasJsConfig(
    "/work", 0, "/home/u", "workspace_write", "",
  )
  assert_eq(config.sessions_dir, "/home/u/.cetas/sessions")
}

///|
test "CetasJsConfig keeps an explicit sessions_dir" {
  let config = CetasJsConfig::CetasJsConfig(
    "/work", 0, "/home/u", "yolo", "/home/u/.cetas/sessions/--work--",
  )
  assert_eq(config.sessions_dir, "/home/u/.cetas/sessions/--work--")
}
