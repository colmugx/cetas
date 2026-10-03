///|
async test "native input router gives focused UiRequest precedence over ESC" {
  let ui = NativeUiPort::new()
  let controller = NativeUiController::new(ui)
  let router = NativeInputRouter::new(controller)

  @async.with_task_group(group => {
    let waiter = group.spawn(async fn() {
      let response : Result[@posoco.UiResponse, @posoco.UiError] = Ok(
        ui.request(@posoco.UiRequest::Confirm(prompt="approve?")),
      ) catch {
        error => Err(error)
      }
      response
    })

    for _ in 0..<32 {
      if router.pump_ui() {
        break
      }
      @async.pause()
    }
    assert_true(router.ui_active())

    match router.route_key(
      validation_key(3U, 0U, 0U, 1U),
      1000UL,
      false,
      true,
      false,
      false,
      false,
    ) {
      RouteUiSettled => ()
      _ => fail("ESC must settle focused UiRequest")
    }
    assert_false(router.ui_active())

    match waiter.wait() {
      Ok(@posoco.UiResponse::Cancelled) => ()
      Ok(other) => fail("ESC delivered wrong response: " + other.to_string())
      Err(error) => fail("focused request failed: " + error.to_string())
    }
  })
}

///|
async test "native input router keeps ctrl+c global while UiRequest is focused" {
  let ui = NativeUiPort::new()
  let controller = NativeUiController::new(ui)
  let router = NativeInputRouter::new(controller)

  @async.with_task_group(group => {
    let waiter = group.spawn(async fn() {
      let response : Result[@posoco.UiResponse, @posoco.UiError] = Ok(
        ui.request(@posoco.UiRequest::Confirm(prompt="approve?")),
      ) catch {
        error => Err(error)
      }
      response
    })

    for _ in 0..<32 {
      if router.pump_ui() {
        break
      }
      @async.pause()
    }
    assert_true(router.ui_active())

    assert_true(
      router.route_key(
        validation_key(1U, 99U, @ui.modifier_control(), 1U),
        1000UL,
        false,
        true,
        false,
        false,
        false,
      ) == RouteShell(InputShutdown),
    )
    assert_true(router.ui_active())

    // Settle the parked waiter so the task group can join.
    match router.route_key(
      validation_key(3U, 0U, 0U, 1U),
      1001UL,
      false,
      true,
      false,
      false,
      false,
    ) {
      RouteUiSettled => ()
      _ => fail("cleanup ESC must settle request")
    }
    ignore(waiter.wait())
  })
}
