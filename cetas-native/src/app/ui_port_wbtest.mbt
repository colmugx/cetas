///|
async fn take_pending_ui_request(
  ui : NativeUiPort,
) -> PendingUiRequest {
  for _ in 0..<32 {
    match ui.take_request() {
      Some(request) => return request
      None => @async.pause()
    }
  }
  fail("native UI request was not published")
}

///|
async test "native UiPort suspends requests until terminal-side response" {
  let ui = NativeUiPort::new()

  ui.render(@posoco.UiRender::{
    slot: @posoco.Status,
    key: "status",
    title: Some("Native"),
    body: @posoco.UiBody::Text("ready"),
    ttl_ms: None,
  })
  guard ui.take_render() is Some(rendered) else {
    fail("render intent was not queued")
  }
  assert_eq(rendered.key, "status")
  assert_true(ui.take_render() is None)

  @async.with_task_group(group => {
    let first = group.spawn(async fn() {
      let result : Result[@posoco.UiResponse, @posoco.UiError] = Ok(
        ui.request(@posoco.UiRequest::Confirm(prompt="first?")),
      ) catch {
        error => Err(error)
      }
      result
    })
    let second = group.spawn(async fn() {
      let result : Result[@posoco.UiResponse, @posoco.UiError] = Ok(
        ui.request(@posoco.UiRequest::Select(
          prompt="second?",
          options=["a", "b"],
          default=Some(0),
        )),
      ) catch {
        error => Err(error)
      }
      result
    })

    let a = take_pending_ui_request(ui)
    let b = take_pending_ui_request(ui)
    assert_true(a.id() != b.id())

    // Resolve in reverse publication order to prove each request owns its
    // response rendezvous rather than sharing a global "current promise".
    let (confirm, select) = match (a.request(), b.request()) {
      (@posoco.UiRequest::Confirm(..), @posoco.UiRequest::Select(..)) => (a, b)
      (@posoco.UiRequest::Select(..), @posoco.UiRequest::Confirm(..)) => (b, a)
      _ => {
        fail("unexpected native UI request pair")
      }
    }

    assert_true(select.respond(@posoco.UiResponse::Selected(1)))
    assert_false(select.respond(@posoco.UiResponse::Selected(0)))
    assert_true(confirm.respond(@posoco.UiResponse::Yes))

    match first.wait() {
      Ok(@posoco.UiResponse::Yes) => ()
      Ok(other) => fail("first request received wrong response: " + other.to_string())
      Err(error) => fail("first request failed: " + error.to_string())
    }
    match second.wait() {
      Ok(@posoco.UiResponse::Selected(1)) => ()
      Ok(other) => fail("second request received wrong response: " + other.to_string())
      Err(error) => fail("second request failed: " + error.to_string())
    }
  })
}
