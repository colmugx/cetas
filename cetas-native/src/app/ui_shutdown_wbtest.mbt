///|
async test "native UiPort close cancels queued requests" {
  let ui = NativeUiPort::new()

  @async.with_task_group(group => {
    let waiter = group.spawn(async fn() {
      let result : Result[@posoco.UiResponse, @posoco.UiError] = Ok(
        ui.request(@posoco.UiRequest::Confirm(prompt="queued?")),
      ) catch {
        error => Err(error)
      }
      result
    })

    let mut queued = false
    for _ in 0..<32 {
      let next = ui.requests.try_get() catch { _ => None }
      match next {
        Some(pending) => {
          assert_true(ui.requests.try_put(pending))
          queued = true
          break
        }
        None => @async.pause()
      }
    }
    assert_true(queued)

    ui.close()
    assert_true(ui.is_closed())

    match waiter.wait() {
      Ok(@posoco.UiResponse::Cancelled) => ()
      Ok(other) => fail("queued close delivered wrong response: " + other.to_string())
      Err(error) => fail("queued request failed: " + error.to_string())
    }
  })
}

///|
async test "native UiController close cancels active request" {
  let ui = NativeUiPort::new()
  let controller = NativeUiController::new(ui)

  @async.with_task_group(group => {
    let waiter = group.spawn(async fn() {
      let result : Result[@posoco.UiResponse, @posoco.UiError] = Ok(
        ui.request(@posoco.UiRequest::Confirm(prompt="active?")),
      ) catch {
        error => Err(error)
      }
      result
    })

    pump_native_ui_controller(controller)
    assert_true(controller.is_active())
    controller.close()
    assert_false(controller.is_active())
    assert_true(ui.is_closed())

    match waiter.wait() {
      Ok(@posoco.UiResponse::Cancelled) => ()
      Ok(other) => fail("active close delivered wrong response: " + other.to_string())
      Err(error) => fail("active request failed: " + error.to_string())
    }
  })
}
