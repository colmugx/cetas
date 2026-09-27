///|
struct MemohOptionsTestPort {
  reasoning_efforts : Array[String]
}

///|
pub impl @posoco.ModelPort for MemohOptionsTestPort with fn chat(
  _self : MemohOptionsTestPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  raise @posoco.ModelError::Transport(
    "model option test port was not expected to chat",
  )
}

///|
pub impl @posoco.ModelPort for MemohOptionsTestPort with fn compact(
  _self : MemohOptionsTestPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "model option test port does not implement compact",
  )
}

///|
pub impl @posoco.ModelPort for MemohOptionsTestPort with fn provider_config(
  self : MemohOptionsTestPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::ProviderConfig(
    reasoning_effort_values=self.reasoning_efforts,
  )
}

///|
pub extend MemohOptionsTestPort with @posoco.ModelPort::{
  chat,
  compact,
  provider_config,
}

///|
fn memoh_test_slot(
  id : String,
  label : String,
  context_window : Int,
  efforts : Array[String],
) -> @llm.ModelSlot {
  let port : &@posoco.ModelPort = MemohOptionsTestPort::{
    reasoning_efforts: efforts,
  }
  let base = @llm.ModelSlot::ModelSlot(
    id~,
    label~,
    provider_id="test",
    model_id=id,
    port~,
    thinking_efforts=efforts,
    context_window=Some(context_window),
    default_effort=if efforts.is_empty() { None } else { Some(efforts[0]) },
  )
  if efforts.is_empty() {
    base
  } else {
    { ..base, rebuild_on_effort: Some(_ => base), }
  }
}

///|
test "Memoh model options expose authoritative model and effort state" {
  let first = memoh_test_slot("test/a", "Model A", 128000, ["low", "high"])
  let second = memoh_test_slot("test/b", "Model B", 1000000, [])
  let router = @llm.RouterModelPort(slots=[first, second])
  let options = memoh_config_options(router)
  assert_eq(options.length(), 2)
  assert_eq(options[0].id, "model")
  assert_eq(options[1].id, "effort")
  match options[0].kind {
    @acp.SessionConfigOptionKind::Select(select) => {
      assert_eq(select.current_value, "test/a")
      match select.options {
        @acp.SessionConfigSelectOptions::Ungrouped(values) => {
          assert_eq(values.length(), 2)
          assert_eq(values[0].value, "test/a")
          assert_eq(values[1].value, "test/b")
        }
        _ => fail("expected ungrouped model options")
      }
    }
    _ => fail("expected model select option")
  }
}

///|
test "Memoh model switch refreshes option snapshot without persistence" {
  let first = memoh_test_slot("test/a", "Model A", 128000, ["low", "high"])
  let second = memoh_test_slot("test/b", "Model B", 1000000, [])
  let router = @llm.RouterModelPort(slots=[first, second])
  let bridge = @ext_acp.AcpBridge(context_window=Some(128000))

  let switched = apply_memoh_config_option(
    router,
    bridge,
    "model",
    @acp.SessionConfigValue::ValueId("test/b"),
  ).unwrap()

  assert_eq(router.active_slot_id(), "test/b")
  assert_eq(router.active_effort(), None)
  assert_eq(switched.length(), 1)
  assert_eq(switched[0].id, "model")
}

///|
test "Memoh effort switch stays session-local" {
  let slot = memoh_test_slot("test/a", "Model A", 128000, ["low", "high"])
  let router = @llm.RouterModelPort(slots=[slot])
  let bridge = @ext_acp.AcpBridge(context_window=Some(128000))

  let options = apply_memoh_config_option(
    router,
    bridge,
    "effort",
    @acp.SessionConfigValue::ValueId("high"),
  ).unwrap()

  assert_eq(router.active_effort(), Some("high"))
  assert_eq(options.length(), 2)
  match options[1].kind {
    @acp.SessionConfigOptionKind::Select(select) =>
      assert_eq(select.current_value, "high")
    _ => fail("expected effort select option")
  }
}
