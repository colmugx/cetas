/// Pull-based native UiPort broker.
///
/// Posoco calls `request()` from an agent coroutine. The request is published
/// into an async-safe queue and that coroutine suspends on a per-request
/// response queue. The terminal loop stays in control: it non-blockingly takes
/// pending requests/renders and resolves requests after user input.
///
/// No Rust callback, terminal handle, or renderer object crosses this layer.

///|
pub struct PendingUiRequest {
  id : Int
  request : @posoco.UiRequest
  response : @aqueue.Queue[@posoco.UiResponse]
  mut resolved : Bool
}

///|
pub fn PendingUiRequest::id(self : PendingUiRequest) -> Int {
  self.id
}

///|
pub fn PendingUiRequest::request(
  self : PendingUiRequest,
) -> @posoco.UiRequest {
  self.request
}

///|
/// Resolve exactly once. False means the token was already resolved or its
/// waiter queue is no longer writable.
pub fn PendingUiRequest::respond(
  self : PendingUiRequest,
  response : @posoco.UiResponse,
) -> Bool {
  if self.resolved {
    return false
  }
  let ok = self.response.try_put(response) catch {
    _ => false
  }
  if ok {
    self.resolved = true
  }
  ok
}

///|
pub struct NativeUiPort {
  renders : @aqueue.Queue[@posoco.UiRender]
  requests : @aqueue.Queue[PendingUiRequest]
  mut next_request_id : Int
}

///|
pub fn NativeUiPort::new() -> NativeUiPort {
  {
    renders: Queue(kind=Unbounded),
    requests: Queue(kind=Unbounded),
    next_request_id: 1,
  }
}

///|
/// Non-blocking render drain for the terminal loop.
pub fn NativeUiPort::take_render(self : NativeUiPort) -> @posoco.UiRender? {
  self.renders.try_get() catch {
    _ => None
  }
}

///|
/// Non-blocking interactive-request drain for the terminal loop.
pub fn NativeUiPort::take_request(
  self : NativeUiPort,
) -> PendingUiRequest? {
  self.requests.try_get() catch {
    _ => None
  }
}

///|
pub impl @posoco.UiPort for NativeUiPort with fn ui_descriptor(
  _self : NativeUiPort,
) -> @posoco.UiDescriptor {
  @posoco.UiDescriptor::empty()
}

///|
pub impl @posoco.UiPort for NativeUiPort with fn render(
  self : NativeUiPort,
  intent : @posoco.UiRender,
) -> Unit {
  ignore(self.renders.try_put(intent) catch {
    _ => false
  })
}

///|
pub impl @posoco.UiPort for NativeUiPort with fn request(
  self : NativeUiPort,
  request : @posoco.UiRequest,
) -> @posoco.UiResponse {
  let id = self.next_request_id
  self.next_request_id += 1
  let response : @aqueue.Queue[@posoco.UiResponse] = Queue(kind=Unbounded)
  let pending = PendingUiRequest::{ id, request, response, resolved: false, }

  self.requests.put(pending) catch {
    _ =>
      raise @posoco.UiError::Unsupported(
        detail="native UI request queue is unavailable",
      )
  }

  response.get() catch {
    _ =>
      raise @posoco.UiError::Unsupported(
        detail="native UI response queue is unavailable",
      )
  }
}

///|
pub extend NativeUiPort with @posoco.UiPort::{ui_descriptor, render, request}
