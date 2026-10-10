///|
/// Registry of UI requests waiting on the browser. The WS handler resolves
/// entries by request id; ask-coroutines block on their one-shot queue.
struct UiRegistry {
  mut next_id : Int
  pending : Map[String, @aqueue.Queue[String]]
}

///|
fn UiRegistry::new() -> UiRegistry {
  { next_id: 1, pending: Map([]), }
}

///|
fn UiRegistry::register(self : UiRegistry) -> (String, @aqueue.Queue[String]) {
  let id = "u-" + self.next_id.to_string()
  self.next_id += 1
  let queue : @aqueue.Queue[String] = Queue(kind=Blocking(1))
  self.pending[id] = queue
  (id, queue)
}

///|
fn UiRegistry::resolve(
  self : UiRegistry,
  request_id : String,
  response : String,
) -> Unit {
  match self.pending.get(request_id) {
    Some(queue) => {
      self.pending.remove(request_id)
      ignore(queue.try_put(response) catch { _ => false })
    }
    None => ()
  }
}

///|
/// The web host's UiPort: renders nothing itself, bridges `UiRequest` to the
/// browser over the event hub and suspends the ask-coroutine on a one-shot
/// queue until the WS response lands.
priv struct HubUiPort {
  hub : EventHub
  session_id : String
  registry : UiRegistry
}

///|
fn HubUiPort::new(
  hub : EventHub,
  registry : UiRegistry,
  session_id : String,
) -> HubUiPort {
  { hub, session_id, registry, }
}

///|
impl @posoco.UiPort for HubUiPort with fn ui_descriptor(_self : HubUiPort) -> @posoco.UiDescriptor {
  @posoco.UiDescriptor::empty()
}

///|
impl @posoco.UiPort for HubUiPort with fn render(
  self : HubUiPort,
  render : @posoco.UiRender,
) -> Unit {
  let entries : Array[Json] = match render.body {
    @posoco.UiBody::Entries(items) => {
      let list : Array[Json] = []
      for item in items {
        list.push(
          Json::object(
            Map::from_array([
              ("key", Json::string(item.key)),
              ("value", Json::string(item.value)),
              (
                "color",
                match item.color {
                  Some(color) => Json::string(color)
                  None => Json::null()
                },
              ),
            ]),
          ),
        )
      }
      list
    }
    _ => []
  }
  self.hub.emit(self.session_id, "", "ui.render", extra=[
    ("key", Json::string(render.key)),
    ("slot", Json::string(@debug.to_string(render.slot))),
    ("entries", Json::array(entries)),
  ])
}

///|
impl @posoco.UiPort for HubUiPort with fn request(
  self : HubUiPort,
  request : @posoco.UiRequest,
) -> @posoco.UiResponse raise {
  let (request_id, queue) = self.registry.register()
  let kind : String = match request {
    @posoco.UiRequest::Input(..) => "input"
    @posoco.UiRequest::Confirm(..) => "confirm"
    @posoco.UiRequest::Select(..) => "select"
  }
  let extra : Array[(String, Json)] = [
    ("request_id", Json::string(request_id)),
    ("kind", Json::string(kind)),
  ]
  match request {
    @posoco.UiRequest::Input(prompt~, default~) => {
      extra.push(("prompt", Json::string(prompt)))
      extra.push(
        (
          "default",
          match default {
            Some(value) => Json::string(value)
            None => Json::null()
          },
        ),
      )
    }
    @posoco.UiRequest::Confirm(prompt~) =>
      extra.push(("prompt", Json::string(prompt)))
    @posoco.UiRequest::Select(prompt~, options~, default~) => {
      extra.push(("prompt", Json::string(prompt)))
      let option_json : Array[Json] = []
      for option in options {
        option_json.push(Json::string(option))
      }
      extra.push(("options", Json::array(option_json)))
      extra.push(
        (
          "default",
          match default {
            Some(index) => Json::number(index.to_double())
            None => Json::null()
          },
        ),
      )
    }
  }
  self.hub.emit(self.session_id, "", "ui.request", extra~)
  let raw = queue.get() catch { _ => return @posoco.UiResponse::Cancelled }
  let parsed = @json.parse(raw) catch {
    _ => return @posoco.UiResponse::Cancelled
  }
  guard parsed is Json::Object(fields) else {
    return @posoco.UiResponse::Cancelled
  }
  if fields.get("cancelled") is Some(Json::True) {
    return @posoco.UiResponse::Cancelled
  }
  if fields.get("selected") is Some(Json::Number(index, ..)) {
    return @posoco.UiResponse::Selected(index.to_int())
  }
  if fields.get("text") is Some(Json::String(value)) {
    return @posoco.UiResponse::Text(value)
  }
  if fields.get("yes") is Some(Json::True) {
    return @posoco.UiResponse::Yes
  }
  if fields.get("no") is Some(Json::False) {
    return @posoco.UiResponse::No
  }
  @posoco.UiResponse::Cancelled
}

///|
/// Seed the harness counters so the statusbar shows them from the start;
/// the observer publishes updates as turns run.
fn seed_status(bus : @devkit.EventBus, label : String) -> Unit {
  @devkit.publish_status_register(
    bus,
    source=label,
    segment="turns",
    label="turns",
    priority=30,
    value="0",
  )
  @devkit.publish_status_register(
    bus,
    source=label,
    segment="steps",
    label="steps",
    priority=31,
    value="0",
  )
}
