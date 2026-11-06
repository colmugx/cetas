///|
/// A cancelled waiter must not retain a live registry entry. Its late reply
/// must not resolve a later waiter with another id.
test "retired UiRequest ids cannot affect subsequent prompts" {
  let registry = UiRegistry::new()
  let (first, _) = registry.register()
  let (second, _) = registry.register()
  assert_true(registry.pending.contains(first))
  assert_true(registry.pending.contains(second))
  registry.forget(first)
  assert_false(registry.pending.contains(first))
  registry.resolve(first, "{\"yes\":true}")
  assert_true(registry.pending.contains(second))
  registry.resolve(second, "{\"cancelled\":true}")
  assert_false(registry.pending.contains(second))
}

///|
/// Shutdown has to wake every still-waiting request, leaving nothing that
/// could be answered by a delayed event from the old terminal.
test "UiRegistry shutdown drains pending requests" {
  let registry = UiRegistry::new()
  let (first, _) = registry.register()
  let (second, _) = registry.register()
  registry.cancel_all()
  assert_false(registry.pending.contains(first))
  assert_false(registry.pending.contains(second))
  registry.cancel_all()
  assert_false(registry.pending.contains(first))
  assert_false(registry.pending.contains(second))
}

///|
/// Cross-kind response payloads and out-of-range approvals fail closed.
test "UiPort response decoding is request-type strict" {
  let select_request = @posoco.UiRequest::Select(
    prompt="Allow shell?",
    options=["once", "session", "deny"],
    default=Some(0),
  )
  match ui_response_for_request(select_request, "{\"selected\":2}") {
    @posoco.UiResponse::Selected(2) => ()
    _ => fail("valid selection was not preserved")
  }
  for
    invalid in [
      "{\"selected\":-1}", "{\"selected\":3}", "{\"selected\":1.5}", "{\"selected\":2147483648}",
      "{\"text\":\"injected\"}", "{\"yes\":true}", "not-json",
    ] {
    assert_true(
      ui_response_for_request(select_request, invalid)
      is @posoco.UiResponse::Cancelled,
    )
  }
  let input = @posoco.UiRequest::Input(prompt="Question?", default=None)
  match ui_response_for_request(input, "{\"text\":\"你好\"}") {
    @posoco.UiResponse::Text(value) => assert_eq(value, "你好")
    _ => fail("input response was not preserved")
  }
  assert_true(
    ui_response_for_request(input, "{\"selected\":0}")
    is @posoco.UiResponse::Cancelled,
  )
  let confirm = @posoco.UiRequest::Confirm(prompt="Confirm?")
  assert_true(
    ui_response_for_request(confirm, "{\"text\":\"yes\"}")
    is @posoco.UiResponse::Cancelled,
  )
  assert_true(
    ui_response_for_request(confirm, "{\"yes\":true}")
    is @posoco.UiResponse::Yes,
  )
  assert_true(
    ui_response_for_request(confirm, "{\"no\":false}") is @posoco.UiResponse::No,
  )
}

///|
/// Exercise an actual suspended UiPort coroutine, not only registry bookkeeping.
async test "UiPort request waits until corresponding answer and retires itself" {
  @async.with_task_group(group => {
    let hub = EventHub::new()
    let frames : Array[String] = []
    hub.attach(fn(frame) { frames.push(frame) })
    let registry = UiRegistry::new()
    let port = HubUiPort::new(hub, registry, "session-a")
    let answer = group.spawn(() => {
      @posoco.UiPort::request(
        port,
        @posoco.UiRequest::Input(prompt="CJK question", default=None),
      )
    })
    @async.sleep(10)
    assert_true(registry.pending.contains("u-1"))
    assert_true(frames.length() >= 1)
    registry.resolve("u-missing", "{\"text\":\"wrong\"}")
    assert_true(registry.pending.contains("u-1"))
    registry.resolve("u-1", "{\"text\":\"你好 Cetas\"}")
    match answer.wait() {
      @posoco.UiResponse::Text(value) => assert_eq(value, "你好 Cetas")
      _ => fail("actual waiter did not receive matching response")
    }
    assert_false(registry.pending.contains("u-1"))
    assert_true(frames.join("\n").contains("ui.dismiss"))
  })
}

///|
/// Shutdown unblocks *all* suspended approval/questions; late replies cannot
/// resurrect a retired request. A separate waiter must remain independent.
async test "UiPort shutdown wakes simultaneous waiters fail closed" {
  @async.with_task_group(group => {
    let hub = EventHub::new()
    let registry = UiRegistry::new()
    let port = HubUiPort::new(hub, registry, "session-a")
    let approval = group.spawn(() => {
      @posoco.UiPort::request(
        port,
        @posoco.UiRequest::Select(
          prompt="Approve shell?",
          options=["once", "deny"],
          default=None,
        ),
      )
    })
    let question = group.spawn(() => {
      @posoco.UiPort::request(
        port,
        @posoco.UiRequest::Input(prompt="Question", default=None),
      )
    })
    @async.sleep(10)
    assert_true(registry.pending.contains("u-1"))
    assert_true(registry.pending.contains("u-2"))
    registry.cancel_all()
    assert_true(approval.wait() is @posoco.UiResponse::Cancelled)
    assert_true(question.wait() is @posoco.UiResponse::Cancelled)
    assert_false(registry.pending.contains("u-1"))
    assert_false(registry.pending.contains("u-2"))
    registry.resolve("u-1", "{\"selected\":0}")
    registry.resolve("u-2", "{\"text\":\"late\"}")
    assert_false(registry.pending.contains("u-1"))
    assert_false(registry.pending.contains("u-2"))
  })
}

///|
/// Direct task cancellation must retire the pending request even when no
/// host ui_response arrives. This covers turn abort and provider cancellation.
async test "UiPort suspended task cancellation removes request and dismisses UI" {
  @async.with_task_group(group => {
    let hub = EventHub::new()
    let frames : Array[String] = []
    hub.attach(fn(frame) { frames.push(frame) })
    let registry = UiRegistry::new()
    let port = HubUiPort::new(hub, registry, "session-a")
    let waiter = group.spawn(
      () => {
        @posoco.UiPort::request(
          port,
          @posoco.UiRequest::Select(
            prompt="Approve tool?",
            options=["allow", "deny"],
            default=None,
          ),
        )
      },
      allow_failure=true,
    )
    @async.sleep(10)
    assert_true(registry.pending.contains("u-1"))
    waiter.cancel()
    let _ = waiter.wait() catch { _ => @posoco.UiResponse::Cancelled }
    assert_false(registry.pending.contains("u-1"))
    assert_true(frames.join("\n").contains("ui.dismiss"))
    registry.resolve("u-1", "{\"selected\":0}")
    assert_false(registry.pending.contains("u-1"))
  })
}
