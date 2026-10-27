///|
/// P0 acceptance pin: on the manifest-composition path the built-in memory
/// surface (memory_search / memory_add over aggregated MemoryPort sources)
/// must lead the model-facing catalog. This verifies the posoco 0.23
/// compose_tool_catalog basic layer from the cetas composition shape,
/// closing the old "catalog_source misses built-in Memory tools" defect if
/// it holds.

///|
struct MemoryCatalogRecordingModel {
  seen_tools : Array[Array[@posoco.ToolDef]]
}

///|
impl @posoco.ModelPort for MemoryCatalogRecordingModel with fn provider_config(
  _self : MemoryCatalogRecordingModel,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
impl @posoco.ModelPort for MemoryCatalogRecordingModel with fn chat(
  self : MemoryCatalogRecordingModel,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  tool_definitions : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  self.seen_tools.push(tool_definitions.copy())
  @posoco.tk_stop_response("done")
}

///|
impl @posoco.ModelPort for MemoryCatalogRecordingModel with fn compact(
  _self : MemoryCatalogRecordingModel,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  abort("compact is not part of this probe")
}

///|
struct MemoryCatalogFakeMemory {}

///|
impl @posoco.MemoryPort for MemoryCatalogFakeMemory with fn inbound(
  _self : MemoryCatalogFakeMemory,
  session_id~ : String,
  request~ : String,
) -> String? raise @posoco.MemoryError {
  ignore(session_id)
  ignore(request)
  None
}

///|
impl @posoco.MemoryPort for MemoryCatalogFakeMemory with fn store(
  _self : MemoryCatalogFakeMemory,
  content~ : String,
  metadata~ : Map[String, Json],
) -> String raise @posoco.MemoryError {
  ignore(content)
  ignore(metadata)
  "probe-id"
}

///|
impl @posoco.MemoryPort for MemoryCatalogFakeMemory with fn search(
  _self : MemoryCatalogFakeMemory,
  query~ : String,
  top_k? : Int32,
) -> String? raise @posoco.MemoryError {
  ignore(query)
  ignore(top_k)
  None
}

///|
impl @posoco.MemoryPort for MemoryCatalogFakeMemory with fn delete(
  _self : MemoryCatalogFakeMemory,
  id : String,
) -> Unit raise @posoco.MemoryError {
  ignore(id)
}

///|
async test "manifest path leads the catalog with memory tools" {
  let model = MemoryCatalogRecordingModel::{ seen_tools: [], }
  let memory = MemoryCatalogFakeMemory::{ }
  let runtime = @runtime.PortRuntime(model=model as &@posoco.ModelPort)
  let agent = @posoco.Agent::with_runtime(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model as &@posoco.ModelPort)),
      @posoco.tk_ext(id="mem", memory=[memory as &@posoco.MemoryPort]),
    ],
    config=@posoco.tk_config(),
    runtime=runtime as &@runtime.Runtime,
  ) catch {
    error => fail("composition failed: \{error}")
  }
  let result = agent.run_turn(@posoco.tk_user_msg("hello"), "session_1")
  assert_eq(result.final_session_id, "session_1")
  assert_eq(model.seen_tools.length(), 1)
  let names = model.seen_tools[0].map(fn(def) { def.name.to_string() })
  assert_true(names.contains("memory_add"), msg=names.join(","))
  assert_true(names.contains("memory_search"), msg=names.join(","))
}
