///|
test "native UiRequest input panel edits and submits text" {
  let panel = UiRequestPanelModel::new(
    @posoco.UiRequest::Input(prompt="name", default=Some("ab")),
  )
  assert_eq(panel.kind(), UiPanelInput)
  assert_eq(panel.input_text(), "ab")

  ignore(panel.handle_key(validation_key(7U, 0U, 0U, 1U))) // left
  ignore(panel.handle_key(validation_key(1U, 88U, 1U, 1U))) // Shift+X
  assert_eq(panel.input_text(), "aXb")

  ignore(panel.handle_key(validation_key(4U, 0U, 0U, 1U))) // backspace
  panel.handle_paste("YZ")
  assert_eq(panel.input_text(), "aYZb")

  match panel.handle_key(validation_key(2U, 0U, 0U, 1U)) {
    Some(@posoco.UiResponse::Text(value)) => assert_eq(value, "aYZb")
    _ => fail("Enter must submit input text")
  }
}

///|
test "native UiRequest confirm and select preserve selection semantics" {
  let confirm = UiRequestPanelModel::new(
    @posoco.UiRequest::Confirm(prompt="continue?"),
  )
  assert_eq(confirm.kind(), UiPanelConfirm)
  assert_eq(confirm.selected_index(), 0)
  ignore(confirm.handle_key(validation_key(10U, 0U, 0U, 1U)))
  match confirm.handle_key(validation_key(2U, 0U, 0U, 1U)) {
    Some(@posoco.UiResponse::No) => ()
    _ => fail("second confirm option must return No")
  }

  let select = UiRequestPanelModel::new(
    @posoco.UiRequest::Select(
      prompt="pick",
      options=["a", "b", "c"],
      default=Some(1),
    ),
  )
  assert_eq(select.kind(), UiPanelSelect)
  assert_eq(select.selected_index(), 1)

  ignore(select.handle_key(validation_key(14U, 0U, 0U, 1U))) // end
  assert_eq(select.selected_index(), 2)
  ignore(select.handle_key(validation_key(10U, 0U, 0U, 1U))) // down wraps
  assert_eq(select.selected_index(), 0)
  match select.handle_key(validation_key(2U, 0U, 0U, 1U)) {
    Some(@posoco.UiResponse::Selected(0)) => ()
    _ => fail("Enter must return selected index")
  }

  let cancel = UiRequestPanelModel::new(
    @posoco.UiRequest::Select(
      prompt="pick",
      options=["a"],
      default=None,
    ),
  )
  match cancel.handle_key(validation_key(3U, 0U, 0U, 1U)) {
    Some(@posoco.UiResponse::Cancelled) => ()
    _ => fail("Escape must cancel UiRequest")
  }
}
