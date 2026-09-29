///|
/// ui_wbtest.mbt — TerminalUiPort's three primitives over the scripted
/// FakeTty, plus the degradation raise and the no-op surfaces.

///|
async fn tk_ui_request(
  req : @posoco.UiRequest,
  tty : FakeTty,
) -> Result[@posoco.UiResponse, @error.UiError] {
  let port = TerminalUiPort::TerminalUiPort(tty=Some(tty.channel()))
  Ok(@posoco.UiPort::request(port, req)) catch {
    error => Err(error)
  }
}

///|
async test "ui input returns text, honors the default on bare enter, and cancels on eof" {
  let tty = FakeTty::FakeTty(["hello there"])
  match
    tk_ui_request(@posoco.UiRequest::Input(prompt="name", default=None), tty) {
    Ok(@posoco.UiResponse::Text(text)) => assert_eq(text, "hello there")
    _ => fail("input must return the typed text")
  }
  // Bare enter falls back to the advertised default.
  let default_tty = FakeTty::FakeTty([""])
  match
    tk_ui_request(
      @posoco.UiRequest::Input(prompt="name", default=Some("world")),
      default_tty,
    ) {
    Ok(@posoco.UiResponse::Text(text)) => assert_eq(text, "world")
    _ => fail("bare enter must take the default")
  }
  let eof_tty = FakeTty::FakeTty([])
  match
    tk_ui_request(
      @posoco.UiRequest::Input(prompt="name", default=None),
      eof_tty,
    ) {
    Ok(@posoco.UiResponse::Cancelled) => ()
    _ => fail("eof must cancel")
  }
}

///|
async test "ui confirm maps y/n, defaults to no on bare enter, re-prompts garbage, cancels on eof" {
  let yes = FakeTty::FakeTty(["y"])
  assert_true(
    tk_ui_request(@posoco.UiRequest::Confirm(prompt="proceed?"), yes)
    is Ok(@posoco.UiResponse::Yes),
  )
  let no = FakeTty::FakeTty(["no"])
  assert_true(
    tk_ui_request(@posoco.UiRequest::Confirm(prompt="proceed?"), no)
    is Ok(@posoco.UiResponse::No),
  )
  // Bare enter is a no.
  let bare = FakeTty::FakeTty([""])
  assert_true(
    tk_ui_request(@posoco.UiRequest::Confirm(prompt="proceed?"), bare)
    is Ok(@posoco.UiResponse::No),
  )
  // Garbage re-prompts, then a real answer lands.
  let garbage = FakeTty::FakeTty(["maybe", "y"])
  match tk_ui_request(@posoco.UiRequest::Confirm(prompt="proceed?"), garbage) {
    Ok(@posoco.UiResponse::Yes) => ()
    _ => fail("garbage must re-prompt before the answer")
  }
  assert_eq(garbage.writes[1], "unrecognized answer; reply y or n\n")
  let eof = FakeTty::FakeTty([])
  assert_true(
    tk_ui_request(@posoco.UiRequest::Confirm(prompt="proceed?"), eof)
    is Ok(@posoco.UiResponse::Cancelled),
  )
}

///|
async test "ui select renders the numbered menu, re-prompts invalid, honors the default, cancels on eof" {
  let menu_tty = FakeTty::FakeTty(["2"])
  match
    tk_ui_request(
      @posoco.UiRequest::Select(
        prompt="pick one",
        options=["alpha", "beta"],
        default=None,
      ),
      menu_tty,
    ) {
    Ok(@posoco.UiResponse::Selected(index)) => assert_eq(index, 1)
    _ => fail("select must return the picked index")
  }
  assert_eq(menu_tty.writes[0], "pick one\n")
  assert_eq(menu_tty.writes[1], "  [1] alpha\n")
  assert_eq(menu_tty.writes[2], "  [2] beta\n")
  // Out-of-range and non-numeric answers re-prompt; bare enter takes the default.
  let defaults_tty = FakeTty::FakeTty(["9", "x", "", "1"])
  match
    tk_ui_request(
      @posoco.UiRequest::Select(
        prompt="pick one",
        options=["alpha", "beta"],
        default=Some(0),
      ),
      defaults_tty,
    ) {
    Ok(@posoco.UiResponse::Selected(index)) => assert_eq(index, 0)
    _ => fail("the default must win on bare enter")
  }
  assert_true(defaults_tty.writes.contains("choose a number 1-2\n"))
  let eof = FakeTty::FakeTty([])
  assert_true(
    tk_ui_request(
      @posoco.UiRequest::Select(
        prompt="pick one",
        options=["alpha"],
        default=None,
      ),
      eof,
    )
    is Ok(@posoco.UiResponse::Cancelled),
  )
}

///|
async test "ui raises Unsupported without a tty; render is a no-op and the descriptor is empty" {
  let port = TerminalUiPort::TerminalUiPort(tty=None)
  let outcome : Result[@posoco.UiResponse, @error.UiError] = Ok(
    @posoco.UiPort::request(port, @posoco.UiRequest::Confirm(prompt="proceed?")),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Err(@error.UiError::Unsupported(detail~)) =>
      assert_true(detail.length() > 0)
    _ => fail("a tty-less port must raise Unsupported")
  }
  let intent : @posoco.UiRender = {
    slot: @posoco.UiSlot::Status,
    key: "k",
    title: None,
    body: @posoco.UiBody::Text("ignored"),
    ttl_ms: None,
  }
  @posoco.UiPort::render(port, intent)
  assert_true(
    @posoco.UiPort::ui_descriptor(port).autocomplete_sources.is_empty(),
  )
}
