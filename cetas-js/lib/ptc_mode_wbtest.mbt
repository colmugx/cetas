///|
priv struct PtcStatusCapture {
  events : Array[@devkit.BusEvent]
}

///|
impl @devkit.BusSubscriber for PtcStatusCapture with fn on_bus_event(
  self : PtcStatusCapture,
  event : @devkit.BusEvent,
) -> Unit {
  self.events.push(event)
}

///|
async test "ptc mode command, revisions and model tool visibility" {
  let mode = CetasPtcMode(nested_names=["read", "grep", "bash"])
  assert_eq(mode.mode(), PtcHybrid)
  assert_eq(mode.revision(), 0)
  assert_true(mode.model_sees("read"))
  assert_true(mode.model_sees("run_code"))
  let port = mode as &@posoco.CommandPort
  assert_true(port.commands().any(def => def.id == "ptc"))
  let choices = port.commands()[0].params[0].choices
  assert_eq(choices, Some(["on", "hybrid", "off", "status"]))
  assert_true(port.invoke("ptc", {}) is @posoco.CommandOutcome::NeedsInput(_))
  ignore(port.invoke("ptc", { "action": "on" }))
  assert_eq(mode.mode(), PtcOnly)
  assert_eq(mode.revision(), 1)
  assert_false(mode.model_sees("read"))
  assert_false(mode.model_sees("grep"))
  assert_true(mode.model_sees("run_code"))
  assert_true(mode.model_sees("mcp__search"))
  ignore(port.invoke("ptc", { "action": "on" }))
  ignore(port.invoke("ptc", { "action": "status" }))
  assert_eq(mode.revision(), 1)
  ignore(port.invoke("ptc", { "action": "off" }))
  assert_false(mode.model_sees("run_code"))
  assert_true(mode.model_sees("bash"))
  assert_eq(mode.revision(), 2)
  ignore(port.invoke("ptc", { "action": "hybrid" }))
  assert_true(mode.model_sees("run_code"))
  assert_true(mode.model_sees("read"))
  assert_eq(mode.revision(), 3)
  assert_true(
    port.invoke("ptc", { "action": "not-a-mode" })
    is @posoco.CommandOutcome::Failure(_),
  )
  assert_eq(mode.revision(), 3)
}

///|
test "ptc status bus initializes, updates, unregisters, and ignores no-ops" {
  let bus = @devkit.EventBus()
  let capture = PtcStatusCapture::{ events: [], }
  bus.subscribe(capture)
  let mode = CetasPtcMode(bus=Some(bus), nested_names=["read"])
  assert_eq(capture.events.length(), 1)
  assert_eq(capture.events[0].source, "posoco_ext_bunraku")
  json_inspect(capture.events[0].data, content={
    "op": "register",
    "segment": "ptc",
    "priority": 11,
    "value": "Hybrid",
    "color": "muted",
  })
  mode.set(PtcOnly)
  json_inspect(capture.events[1].data, content={
    "op": "register",
    "segment": "ptc",
    "priority": 11,
    "value": "PTC",
    "color": "accent",
  })
  mode.set(PtcOnly)
  assert_eq(capture.events.length(), 2)
  mode.set(PtcDirect)
  json_inspect(capture.events[2].data, content={
    "op": "unregister",
    "segment": "ptc",
  })
}
