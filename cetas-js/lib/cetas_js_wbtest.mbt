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
test "JsUiPort wire encodes entries bodies with optional color roles" {
  let raw = ui_render_event_to_json({
    slot: @port.UiSlot::Status,
    key: "statusbar",
    title: None,
    body: @port.UiBody::Entries([
      { key: "model", value: "deepseek-v4-pro", color: Some("accent"), },
      { key: "session", value: "s1", color: None, },
    ]),
    ttl_ms: None,
  })
  let json = @json.parse(raw)
  match json {
    Json::Object(event) =>
      match event["render"] {
        Json::Object(render) =>
          match render["body"] {
            Json::Object(body) => {
              assert_eq(body["type"], Json::string("entries"))
              match body["entries"] {
                Json::Array(entries) => {
                  assert_eq(entries.length(), 2)
                  match entries[0] {
                    Json::Object(first) => {
                      assert_eq(first["key"], Json::string("model"))
                      assert_eq(first["value"], Json::string("deepseek-v4-pro"))
                      assert_eq(first["color"], Json::string("accent"))
                    }
                    _ => fail("first entry must be an object")
                  }
                  match entries[1] {
                    Json::Object(second) => {
                      assert_eq(second["key"], Json::string("session"))
                      assert_eq(second["value"], Json::string("s1"))
                      // Absent color stays absent on the wire.
                      assert_eq(second.contains("color"), false)
                    }
                    _ => fail("second entry must be an object")
                  }
                }
                _ => fail("entries must be an array")
              }
            }
            _ => fail("body must be an object")
          }
        _ => fail("render must be an object")
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
test "CetasJsConfig empty sessions_dir falls back to the per-project bucket" {
  let config = CetasJsConfig::CetasJsConfig(
    "/work", 0, "/home/u", "workspace_write", "", "",
  )
  assert_eq(
    config.sessions_dir,
    @fs_session.project_sessions_dir("/home/u", "/work"),
  )
  // The fallback is a `session_<slug>_<hash>` bucket, not the flat root.
  assert_true(config.sessions_dir.contains("/.cetas/sessions/session_"))
}

///|
test "CetasJsConfig keeps an explicit sessions_dir" {
  let config = CetasJsConfig::CetasJsConfig(
    "/work", 0, "/home/u", "yolo", "/home/u/.cetas/sessions/--work--", "",
  )
  assert_eq(config.sessions_dir, "/home/u/.cetas/sessions/--work--")
}

///|
test "cetas_js_sessions_dir agrees with the fs-session project layout" {
  assert_eq(
    cetas_js_sessions_dir("/home/u", "/work"),
    @fs_session.project_sessions_dir("/home/u", "/work"),
  )
  // Sibling paths that a slug alone would collide get distinct buckets.
  assert_true(
    cetas_js_sessions_dir("/home/u", "/a/b_c") !=
    cetas_js_sessions_dir("/home/u", "/a/b/c"),
  )
}

///|
async test "cetas_js_session_titles lists a missing directory as empty" {
  let missing = "/tmp/cetas-js-titles-missing-nonexistent"
  let raw = cetas_js_session_titles(missing).wait()
  assert_eq(raw, "[]")
}

///|
test "turn_event_to_json maps ToolCallDelta onto tool_args_delta" {
  let event : @posoco.TurnEvent = StreamChunkReceived(
    chunk=ToolCallDelta(
      index=1,
      id=Some("call_9"),
      name=Some("write"),
      arguments_delta=Some("{\"path\""),
    ),
  )
  let json = @json.parse(turn_event_to_json(event).stringify())
  match json {
    Json::Object(fields) => {
      assert_eq(fields["type"], Json::string("tool_args_delta"))
      assert_eq(fields["index"], Json::number(1.0))
      assert_eq(fields["id"], Json::string("call_9"))
      assert_eq(fields["name"], Json::string("write"))
      assert_eq(fields["delta"], Json::string("{\"path\""))
    }
    _ => fail("event must be an object")
  }
}

///|
test "turn_event_to_json carries only Some fields on later fragments" {
  let event : @posoco.TurnEvent = StreamChunkReceived(
    chunk=ToolCallDelta(
      index=0,
      id=None,
      name=None,
      arguments_delta=Some("abc"),
    ),
  )
  let json = @json.parse(turn_event_to_json(event).stringify())
  match json {
    Json::Object(fields) => {
      assert_eq(fields["type"], Json::string("tool_args_delta"))
      assert_eq(fields["index"], Json::number(0.0))
      assert_eq(fields.get("id"), None)
      assert_eq(fields.get("name"), None)
      assert_eq(fields["delta"], Json::string("abc"))
    }
    _ => fail("event must be an object")
  }
}

///|
test "turn_event_to_json skips StreamChunksDropped (null sentinel)" {
  let event : @posoco.TurnEvent = StreamChunksDropped(count=3)
  match turn_event_to_json(event) {
    Json::Null => ()
    _ => fail("expected Json null skip sentinel")
  }
}
