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
