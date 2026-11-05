///|
/// Typed status capture: every `@kit_events.StatusChanged` op the mode
/// publishes, in delivery order, with the namespace it was attributed to.
priv struct PtcStatusCapture {
  ops : Array[@kit_events.StatusOp]
  publishers : Array[String]
}

///|
fn ptc_status_capture(system : @posoco.EventSystem) -> PtcStatusCapture {
  let capture = PtcStatusCapture::{ ops: [], publishers: [], }
  ignore(
    system.subscribe(fn(envelope) {
      match @kit_events.status_changed_of(envelope) {
        Some(op) => {
          capture.ops.push(op)
          capture.publishers.push(
            @kit_events.publisher_id(envelope).unwrap_or(""),
          )
        }
        None => ()
      }
    }),
  )
  capture
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
test "ptc status publishes typed ops on the session event system" {
  let system = @posoco.EventSystem()
  let capture = ptc_status_capture(system)
  let mode = CetasPtcMode(
    events=@cetas_core.mint_events_publisher(system, owner="posoco_ext_bunraku"),
  )
  assert_eq(capture.ops.length(), 1)
  assert_eq(capture.publishers[0], "posoco_ext_bunraku")
  assert_eq(
    capture.ops[0],
    @kit_events.Register(
      segment="ptc",
      label=None,
      priority=11,
      value=Some("Hybrid"),
      color=Some("muted"),
    ),
  )
  mode.set(PtcOnly)
  assert_eq(
    capture.ops[1],
    @kit_events.Register(
      segment="ptc",
      label=None,
      priority=11,
      value=Some("PTC"),
      color=Some("accent"),
    ),
  )
  mode.set(PtcOnly)
  assert_eq(capture.ops.length(), 2)
  mode.set(PtcDirect)
  assert_eq(capture.ops[2], @kit_events.Unregister(segment="ptc"))
}
