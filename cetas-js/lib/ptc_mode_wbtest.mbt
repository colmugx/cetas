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
fn ptc_exposure_def(name : String, owner : String) -> @posoco.ToolDef {
  {
    name: @posoco.ToolName::unchecked(name),
    description: "probe",
    input_schema: { "type": "object" },
    owner: @posoco.OwnerId::unchecked(owner),
    policy: @posoco.ExecutionPolicy::Parallel,
    exposure: @posoco.ToolExposure::Direct,
    provenance: None,
  }
}

///|
/// Exposure projection replaces the retired model_sees name filter: the
/// kernel narrows every captured definition through tool_exposure.
async test "ptc mode command, revisions and exposure projection" {
  let mode = CetasPtcMode()
  assert_eq(mode.mode(), PtcHybrid)
  assert_eq(mode.revision(), 0)
  let port = mode as &@posoco.CommandPort
  assert_true(port.commands().any(def => def.id == "ptc"))
  let choices = port.commands()[0].params[0].choices
  assert_eq(choices, Some(["on", "hybrid", "off", "status"]))
  assert_true(port.invoke("ptc", {}) is @posoco.CommandOutcome::NeedsInput(_))
  let read = ptc_exposure_def("read", "posoco_ext_read")
  let run_code = ptc_exposure_def("run_code", "posoco_ext_bunraku")
  let outsider = ptc_exposure_def("webfetch", "posoco_ext_webfetch")
  // Hybrid: identity (everything keeps its declared exposure).
  assert_eq(mode.tool_exposure(read), @posoco.ToolExposure::Direct)
  assert_eq(mode.tool_exposure(run_code), @posoco.ToolExposure::Direct)
  assert_eq(mode.tool_exposure(outsider), @posoco.ToolExposure::Direct)
  ignore(port.invoke("ptc", { "action": "on" }))
  assert_eq(mode.mode(), PtcOnly)
  assert_eq(mode.revision(), 1)
  // PtcOnly: the nested face folds into Deferred; the transport stays
  // Direct; everything outside the face keeps its declared exposure.
  assert_eq(mode.tool_exposure(read), @posoco.ToolExposure::Deferred)
  assert_eq(mode.tool_exposure(run_code), @posoco.ToolExposure::Direct)
  assert_eq(mode.tool_exposure(outsider), @posoco.ToolExposure::Direct)
  ignore(port.invoke("ptc", { "action": "on" }))
  ignore(port.invoke("ptc", { "action": "status" }))
  assert_eq(mode.revision(), 1)
  ignore(port.invoke("ptc", { "action": "off" }))
  assert_eq(mode.mode(), PtcDirect)
  assert_eq(mode.revision(), 2)
  // Off: the transport itself is withdrawn.
  assert_eq(mode.tool_exposure(run_code), @posoco.ToolExposure::Disabled)
  assert_eq(mode.tool_exposure(read), @posoco.ToolExposure::Direct)
  ignore(port.invoke("ptc", { "action": "hybrid" }))
  assert_eq(mode.tool_exposure(read), @posoco.ToolExposure::Direct)
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
  let mode = CetasPtcMode(bus=Some(bus))
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

///|
/// Hooks may only narrow: a Deferred-declared definition stays Deferred no
/// matter what the mode hook returns, because the kernel narrows with
/// `ToolExposure::narrow`. This pins the composition order we rely on.
test "ptc exposure hook composes by narrowing only" {
  assert_eq(
    @posoco.ToolExposure::narrow(
      @posoco.ToolExposure::Deferred,
      @posoco.ToolExposure::Direct,
    ),
    @posoco.ToolExposure::Deferred,
  )
  assert_eq(
    @posoco.ToolExposure::narrow(
      @posoco.ToolExposure::Direct,
      @posoco.ToolExposure::Disabled,
    ),
    @posoco.ToolExposure::Disabled,
  )
}
