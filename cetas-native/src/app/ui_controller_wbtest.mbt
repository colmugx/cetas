///|
async fn pump_native_ui_controller(
  controller : NativeUiController,
) -> Unit {
  for _ in 0..<32 {
    if controller.pump() {
      return
    }
    @async.pause()
  }
  fail("native UI controller did not activate pending request")
}

///|
async test "native UI controller settles a suspended UiPort request" {
  let ui = NativeUiPort::new()
  let controller = NativeUiController::new(ui)

  @async.with_task_group(group => {
    let waiter = group.spawn(async fn() {
      let response : Result[@posoco.UiResponse, @posoco.UiError] = Ok(
        ui.request(@posoco.UiRequest::Confirm(prompt="continue?")),
      ) catch {
        error => Err(error)
      }
      response
    })

    pump_native_ui_controller(controller)
    assert_true(controller.is_active())
    assert_eq(controller.active_prompt(), Some("continue?"))
    assert_eq(controller.active_kind(), Some(UiPanelConfirm))
    assert_eq(controller.active_selected_index(), Some(0))

    // Down selects "No"; Enter resolves the per-request rendezvous.
    assert_false(controller.handle_key(validation_key(10U, 0U, 0U, 1U)))
    assert_eq(controller.active_selected_index(), Some(1))
    assert_true(controller.handle_key(validation_key(2U, 0U, 0U, 1U)))
    assert_false(controller.is_active())

    match waiter.wait() {
      Ok(@posoco.UiResponse::No) => ()
      Ok(other) => fail("controller delivered wrong response: " + other.to_string())
      Err(error) => fail("controller request failed: " + error.to_string())
    }
  })
}
