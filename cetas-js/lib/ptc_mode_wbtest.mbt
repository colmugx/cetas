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

///|
async test "ptc only rejects direct calls to nested tools with guidance" {
  let mode = CetasPtcMode(nested_names=["read", "bash"])
  let call = @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call_1"),
    name: @posoco.ToolName::unchecked("bash"),
    arguments: Json::object({ "cmd": Json::string("ls") }),
  }
  mode.set(PtcHybrid)
  guard mode.before_tool(call) is @port.ToolDecision::Approve(call~) else {
    fail("hybrid rejected a direct nested-tool call")
  }
  mode.set(PtcOnly)
  guard mode.before_tool(call) is @port.ToolDecision::Reject(reason~) else {
    fail("ptc only allowed a direct nested-tool call")
  }
  assert_true(reason.contains("run_code"))
  assert_true(reason.contains("bash"))
  let outsider = @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call_2"),
    name: @posoco.ToolName::unchecked("webfetch"),
    arguments: Json::object({ "url": Json::string("https://example.com") }),
  }
  guard mode.before_tool(outsider) is @port.ToolDecision::Approve(..) else {
    fail("ptc only rejected a non-nested tool")
  }
}

///|
priv struct PtcMultiToolProbe {
  calls : Array[String]
}

///|
impl @posoco.ToolProvider for PtcMultiToolProbe with fn list_tools(
  _self : PtcMultiToolProbe,
) -> Array[@posoco.ToolDef] {
  [
    @posoco.tk_tool_def("bash", "execute shell command"),
    @posoco.tk_tool_def("bash_status", "query shell session"),
    @posoco.tk_tool_def("bash_wait", "wait shell session"),
    @posoco.tk_tool_def("bash_kill", "kill shell session"),
  ]
}

///|
impl @posoco.ToolProvider for PtcMultiToolProbe with fn execute(
  self : PtcMultiToolProbe,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  self.calls.push(ctx.name.to_string())
  @posoco.tk_ok_result("ok")
}

///|
async test "PTC selection scopes a multi-tool provider to bash only" {
  let provider = PtcMultiToolProbe::{ calls: [], }
  let allowed = [
    "read", "grep", "glob", "write", "edit", "apply_patch", "bash",
  ]
  let selected = cetas_ptc_select_provider(provider, allowed)
  guard selected is Some(scoped) else {
    fail("multi-tool bash provider was discarded")
  }
  let defs = scoped.list_tools()
  assert_eq(defs.length(), 1)
  assert_eq(defs[0].name.to_string(), "bash")
  let nested_names = defs.map(fn(def) { def.name.to_string() })
  let mode = CetasPtcMode(nested_names~)
  mode.set(PtcOnly)
  assert_false(mode.model_sees("bash"))
  assert_true(mode.model_sees("bash_status"))
  assert_true(mode.model_sees("run_code"))
  let direct : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("direct_1"),
    name: @posoco.ToolName::unchecked("bash"),
    arguments: { "cmd": "echo ok" },
  }
  assert_true(mode.before_tool(direct) is @posoco.ToolDecision::Reject(..))
  let invoked = scoped.execute(
    @posoco.tk_tool_call_ctx(name="bash", arguments={ "cmd": "echo ok" }),
  )
  assert_true(invoked is @posoco.ToolOutcome::Success(..))
  assert_eq(provider.calls, ["bash"])
  let denied = scoped.execute(
    @posoco.tk_tool_call_ctx(name="bash_kill", arguments={}),
  )
  assert_true(denied is @posoco.ToolOutcome::ToolReportedError(..))
  assert_eq(provider.calls, ["bash"])
}
