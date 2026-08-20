///|
/// Whitebox tests for the cetas ACP host: prompt streaming end-to-end, tool
/// rounds through the permission gate, failure surfacing, and cancellation.

// ---------------------------------------------------------------- fixtures

///|
/// Recording stand-in for the ACP client side, wired into a real acp.mbt
/// `AgentContext` through its broker seams.
priv struct FakeAcpClient {
  sent : Array[@acp.SessionUpdateParams]
  asked : Array[@acp.RequestPermissionRequest]
  reply : @acp.RequestPermissionResponse
}

///|
fn FakeAcpClient::FakeAcpClient(
  reply? : @acp.RequestPermissionResponse = {
    outcome: Selected({ option_id: @ext_acp.ACP_ALLOW_ONCE, meta: Omitted }),
    meta: Omitted,
  },
) -> FakeAcpClient {
  { sent: [], asked: [], reply }
}

///|
fn fake_acp_context(client : FakeAcpClient) -> @acp.AgentContext {
  @acp.agent_context(
    request_broker=request => {
      match request {
        SessionRequestPermission(ask) => {
          client.asked.push(ask)
          Ok(AgentReplyRequestPermission(client.reply))
        }
        _ => Err(AgentContextBrokerFailure(method_name="unused-request"))
      }
    },
    notification_broker=notification => {
      match notification {
        SessionUpdate(params) => {
          client.sent.push(params)
          Ok(())
        }
        _ => Ok(())
      }
    },
  )
}

///|
/// One text-only ACP prompt.
fn tk_prompt(text : String) -> Array[@acp.ContentBlock] {
  [Text({ annotations: Omitted, text, meta: Omitted })]
}

///|
/// In-memory WorkspaceFs for selection persistence tests: a plain map plus
/// optional failure injection on the atomic write.
priv struct FakeFs {
  files : Map[String, String]
  mut fail_writes : Bool
}

///|
fn FakeFs::new() -> FakeFs {
  { files: Map::from_array([]), fail_writes: false }
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn exists(self, path) {
  self.files.contains(path)
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn kind(
  _self,
  _path,
  follow_symlink~,
) {
  let _ = follow_symlink
  @workspace.WorkspaceFileKind::File
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn read_file(self, path) {
  match self.files.get(path) {
    Some(content) => content
    None => raise @workspace.WorkspaceFsError::WorkspaceFsError("missing")
  }
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn write_file(self, path, content) {
  self.files[path] = content
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn write_file_atomic(
  self,
  path,
  content,
) {
  if self.fail_writes {
    raise @workspace.WorkspaceFsError::WorkspaceFsError("atomic write failed")
  }
  self.files[path] = content
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn remove(self, path) {
  ignore(self.files.remove(path))
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn rename(
  _self,
  _from,
  _to,
  replace~,
) {
  let _ = replace
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn realpath(_self, path) {
  path
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn readdir(
  _self,
  _path,
  include_hidden~,
) {
  let _ = include_hidden
  []
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn walk(_self, _root, _callback) {

}

///|
impl @workspace.WorkspaceFs for FakeFs with fn mkdir(_self, _path, recursive~) {
  let _ = recursive
}

///|
/// One router slot over a scripted model port. `efforts` empty means the
/// slot advertises no reasoning efforts.
fn tk_router_slot(
  id : String,
  label : String,
  efforts : Array[String],
) -> @llm.ModelSlot {
  let base : @llm.ModelSlot = @llm.ModelSlot::ModelSlot(
    id~,
    label~,
    provider_id="test",
    model_id=id,
    port=@posoco.ScriptedModel([]),
    thinking_efforts=efforts,
    default_effort=if efforts.is_empty() { None } else { Some(efforts[0]) },
  )
  {
    ..base,
    rebuild_on_effort: Some(effort => { ..base, default_effort: Some(effort) }),
  }
}

///|
/// The test router: `test/alpha` advertises low/high efforts, `test/beta`
/// advertises none. `alpha` is the first slot, hence the default.
fn tk_router() -> @llm.RouterModelPort raise @posoco.CompositionError {
  @llm.RouterModelPort::new(slots=[
    tk_router_slot("test/alpha", "Alpha", ["low", "high"]),
    tk_router_slot("test/beta", "Beta", []),
  ])
}

///|
/// Compose a host over a scripted model + recording tool provider through
/// the same `Agent` the product uses. The host carries a two-slot router
/// and a fake fs so config-option tests run without real IO. `refreshables`
/// substitutes fake model-discovery seams for lazy-refresh tests.
fn tk_host(
  steps : Array[@posoco.ScriptedModelStep],
  tools? : @posoco.RecordingToolProvider = @posoco.RecordingToolProvider(
    [],
    Map::from_array([]),
  ),
  fs? : FakeFs = FakeFs::new(),
  refreshables? : Array[&@llm.RefreshableProviderFactory] = [],
) -> (CetasAcpHost, @posoco.ScriptedModel) raise @posoco.CompositionError {
  let model = @posoco.ScriptedModel(steps)
  let bridge = @ext_acp.AcpBridge::new()
  // Production wiring in miniature: the bridge translates approval asks
  // into ACP permission requests; the policy owns which tools ask.
  let policy = @permission.PermissionPolicy::new(
    @permission.Interactive,
    approval=Some(bridge as &@permission.ApprovalSource),
  )
  let router = tk_router()
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="tools", tools=[tools]),
      @posoco.tk_ext(id="io", sessions=[
        @posoco.RecordingSessionStore::RecordingSessionStore(),
      ]),
      bridge,
      policy,
    ],
    config=@posoco.tk_config(),
  )
  (
    CetasAcpHost::of(
      agent~,
      bridge~,
      router~,
      home="/cetas-home",
      fs~,
      refreshables~,
    ),
    model,
  )
}

///|
/// A refreshable seam that answers from a fixed catalog: no network, so
/// lazy-refresh tests exercise the real cetas-core orchestration.
priv struct FakeRefreshFactory {
  fixed_id : String
  catalog : @llm.ProviderModelCatalog
}

///|
impl @llm.RefreshableProviderFactory for FakeRefreshFactory with fn provider_id(
  self : FakeRefreshFactory,
) -> String {
  self.fixed_id
}

///|
impl @llm.RefreshableProviderFactory for FakeRefreshFactory with fn refresh(
  self : FakeRefreshFactory,
  _source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  @llm.ProviderBuildResult::Ready(self.catalog)
}

///|
/// A refreshable seam that always fails, for the degraded-path test.
priv struct FailingRefreshFactory {
  fixed_id : String
}

///|
impl @llm.RefreshableProviderFactory for FailingRefreshFactory with fn provider_id(
  self : FailingRefreshFactory,
) -> String {
  self.fixed_id
}

///|
impl @llm.RefreshableProviderFactory for FailingRefreshFactory with fn refresh(
  self : FailingRefreshFactory,
  _source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  raise @posoco.CompositionError::ManifestSchemaError(
    manifest_id="fake-refresh",
    detail="offline",
  )
}

///|
fn tk_new_session_params() -> @acp.NewSessionParams {
  { cwd: "/", additional_directories: Omitted, mcp_servers: [], meta: Omitted }
}

// ------------------------------------------------------------ prompt input

///|
test "acp_prompt_to_message maps text image and resource link" {
  let message = acp_prompt_to_message([
    Text({ annotations: Omitted, text: "hello", meta: Omitted }),
    Image({
      annotations: Omitted,
      data: "AAAA",
      mime_type: "image/png",
      uri: Omitted,
      meta: Omitted,
    }),
    ResourceLink({
      annotations: Omitted,
      description: Omitted,
      mime_type: Omitted,
      name: "x.md",
      size: Omitted,
      title: Omitted,
      uri: "file:///tmp/x.md",
      meta: Omitted,
    }),
  ])
  match message {
    UserMessage(content~) => {
      assert_eq(content.length(), 3)
      assert_true(content[0] is Text("hello"))
      assert_true(content[1] is Image(media_type="image/png", data="AAAA"))
      assert_true(content[2] is Text("Resource: file:///tmp/x.md"))
    }
    _ => fail("expected user message")
  }
}

///|
async test "new sessions mint incrementing shared ids" {
  let (host, _) = tk_host([])
  let first = host.handle_new_session(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    {
      cwd: "/",
      additional_directories: Omitted,
      mcp_servers: [],
      meta: Omitted,
    },
  )
  let second = host.handle_new_session(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    {
      cwd: "/",
      additional_directories: Omitted,
      mcp_servers: [],
      meta: Omitted,
    },
  )
  assert_eq(first.session_id, "cetas-1")
  assert_eq(second.session_id, "cetas-2")
}

// ------------------------------------------------------------------ prompt

///|
async test "prompt streams the assistant message and ends the turn" {
  let (host, _) = tk_host([
    @posoco.Respond(@posoco.tk_stop_response("hi there")),
  ])
  let client = FakeAcpClient::FakeAcpClient()
  let result = host.handle_prompt(fake_acp_context(client), {
    session_id: "cetas-1",
    prompt: tk_prompt("hello"),
    meta: Omitted,
  })
  assert_true(result.stop_reason is EndTurn)
  // The streamed agent message reached the client with the session stamp.
  assert_true(client.sent.length() >= 1)
  assert_eq(client.sent[0].session_id, "cetas-1")
  let mut saw_text = false
  for frame in client.sent {
    match frame.update {
      AgentMessageChunk(chunk) =>
        match chunk.content {
          Text({ text, .. }) => if text == "hi there" { saw_text = true }
          _ => ()
        }
      _ => ()
    }
  }
  assert_true(saw_text)
}

///|
async test "prompt with a tool round streams the tool call lifecycle" {
  let tools = @posoco.RecordingToolProvider(
    [@posoco.tk_tool_def("echo", "echo the input")],
    Map::from_array([
      ("echo", @posoco.OutcomeOk(@posoco.tk_ok_result("echoed"))),
    ]),
  )
  let (host, _) = tk_host(
    [
      @posoco.Respond(
        @posoco.tk_tool_call_response(
          "echo",
          "c1",
          Json::object({ "command": Json::string("hi") }),
        ),
      ),
      @posoco.Respond(@posoco.tk_stop_response("done")),
    ],
    tools~,
  )
  let client = FakeAcpClient::FakeAcpClient()
  let result = host.handle_prompt(fake_acp_context(client), {
    session_id: "cetas-1",
    prompt: tk_prompt("run echo"),
    meta: Omitted,
  })
  assert_true(result.stop_reason is EndTurn)
  let mut saw_pending = false
  let mut saw_completed = false
  for frame in client.sent {
    match frame.update {
      ToolCall(_) => saw_pending = true
      ToolCallUpdate(update) =>
        if update.tool_call_id == "c1" && update.status is Value(Completed) {
          saw_completed = true
        }
      _ => ()
    }
  }
  assert_true(saw_pending)
  assert_true(saw_completed)
  // The permission round-trip happened through the ACP client.
  assert_eq(client.asked.length(), 1)
  assert_eq(client.asked[0].session_id, "cetas-1")
}

///|
async test "denied tool aborts the turn with the sanitized reason" {
  let tools = @posoco.RecordingToolProvider(
    [@posoco.tk_tool_def("bash", "shell")],
    Map::from_array([("bash", @posoco.OutcomeOk(@posoco.tk_ok_result("ok")))]),
  )
  let (host, _) = tk_host(
    [
      @posoco.Respond(
        @posoco.tk_tool_call_response(
          "bash",
          "c1",
          Json::object({ "command": Json::string("rm -rf /") }),
        ),
      ),
    ],
    tools~,
  )
  let client = FakeAcpClient::FakeAcpClient(reply={
    outcome: Selected({ option_id: @ext_acp.ACP_REJECT_ONCE, meta: Omitted }),
    meta: Omitted,
  })
  let outcome : Result[@acp.PromptResult, @acp.HandlerError] = Ok(
    host.handle_prompt(fake_acp_context(client), {
      session_id: "cetas-1",
      prompt: tk_prompt("rm"),
      meta: Omitted,
    }),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Ok(_) => fail("denied tool must fail the prompt")
    Err(Application(message~)) => assert_true(message.contains("cetas-acp:"))
    Err(_) => fail("expected application error")
  }
}

///|
async test "model failure surfaces as an application error" {
  // ScriptedModel with no steps fails on the first call.
  let (host, _) = tk_host([])
  let client = FakeAcpClient::FakeAcpClient()
  let outcome : Result[@acp.PromptResult, @acp.HandlerError] = Ok(
    host.handle_prompt(fake_acp_context(client), {
      session_id: "cetas-1",
      prompt: tk_prompt("hello"),
      meta: Omitted,
    }),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Ok(_) => fail("exhausted scripted model must fail the prompt")
    Err(Application(message~)) => assert_true(message.contains("cetas-acp:"))
    Err(_) => fail("expected application error")
  }
}

// -------------------------------------------------------------- cancellation

///|
async test "cancel interrupts the session's in-flight turn" {
  let (host, _) = tk_host([])
  // Register a sleep task as the session's in-flight turn, then cancel it
  // through the ACP handler — the same Task::cancel path a real turn uses.
  @async.with_task_group(group => {
    let sleeper = group.spawn(() => {
      @async.sleep(10_000)
      // Placeholder TurnResult: the task's payload is irrelevant here, only
      // its cancellation matters.
      let placeholder : @posoco.TurnResult = {
        message: @posoco.tk_user_msg(""),
        tool_results: [],
        final_session_id: "cetas-1",
      }
      placeholder
    })
    host.in_flight["cetas-1"] = sleeper
    host.handle_cancel(fake_acp_context(FakeAcpClient::FakeAcpClient()), {
      session_id: "cetas-1",
      meta: Omitted,
    })
    let cancelled : Bool = try {
      let _ = sleeper.wait()
      false
    } catch {
      error => @async.is_cancellation_error(error)
    }
    assert_true(cancelled)
  })
}

// ----------------------------------------------------------- config options

///|
/// Find the select arm advertised for one config id.
fn tk_find_option(
  options : Array[@acp.SessionConfigOption],
  id : String,
) -> @acp.SessionConfigSelect? {
  for option in options {
    if option.id == id {
      match option.kind {
        @acp.SessionConfigOptionKind::Select(select) => return Some(select)
        _ => ()
      }
    }
  }
  None
}

///|
/// Unwrap an ungrouped option list.
fn tk_ungrouped(
  options : @acp.SessionConfigSelectOptions,
) -> Array[@acp.SessionConfigSelectOption] raise {
  match options {
    @acp.SessionConfigSelectOptions::Ungrouped(list) => list
    _ => fail("expected ungrouped select options")
  }
}

///|
async test "new session advertises model and effort config options" {
  let (host, _) = tk_host([])
  let result = host.handle_new_session(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    {
      cwd: "/",
      additional_directories: Omitted,
      mcp_servers: [],
      meta: Omitted,
    },
  )
  guard result.config_options is Value(options) else {
    fail("config options must be advertised")
  }
  // Model arm: current is the first slot; both slots listed by display name.
  match tk_find_option(options, "model") {
    Some(select) => {
      assert_eq(select.current_value, "test/alpha")
      let listed = tk_ungrouped(select.options)
      assert_eq(listed.length(), 2)
      assert_true(listed[0] is { value: "test/alpha", name: "Alpha", .. })
      assert_true(listed[1] is { value: "test/beta", name: "Beta", .. })
    }
    None => fail("model arm missing")
  }
  // Effort arm: alpha advertises low/high; current is the slot default.
  match tk_find_option(options, "effort") {
    Some(select) => {
      assert_eq(select.current_value, "low")
      let listed = tk_ungrouped(select.options)
      assert_eq(listed.length(), 2)
      assert_true(listed[0] is { value: "low", .. })
      assert_true(listed[1] is { value: "high", .. })
    }
    None => fail("effort arm missing for effort-advertising slot")
  }
  // A slot without advertised efforts suppresses the effort arm.
  host.router.switch_slot("test/beta")
  let again = host.handle_new_session(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    {
      cwd: "/",
      additional_directories: Omitted,
      mcp_servers: [],
      meta: Omitted,
    },
  )
  guard again.config_options is Value(options) else {
    fail("config options must stay advertised")
  }
  assert_true(tk_find_option(options, "model") is Some(_))
  assert_true(tk_find_option(options, "effort") is None)
}

///|
async test "apply_config_option switches the model and persists flat keys" {
  let fs = FakeFs::new()
  fs.files["/cetas-home/.cetas/settings.json"] = "{\"providers\":{\"kimi\":{}}}"
  let router = tk_router()
  match
    apply_config_option(
      router,
      fs,
      "/cetas-home",
      "model",
      @acp.SessionConfigValue::ValueId("test/beta"),
    ) {
    Ok(options) => {
      assert_eq(router.active_slot_id(), "test/beta")
      match tk_find_option(options, "model") {
        Some(select) => assert_eq(select.current_value, "test/beta")
        None => fail("model arm missing")
      }
      assert_true(tk_find_option(options, "effort") is None)
    }
    Err(message) => fail("model switch must apply: " + message)
  }
  let saved = @json.parse(fs.files["/cetas-home/.cetas/settings.json"]) catch {
    _ => fail("saved settings must parse")
  }
  match saved {
    Json::Object(fields) => {
      assert_true(fields.get("providers") is Some(Json::Object({ .. })))
      assert_true(fields.get("model") is Some(Json::String("test/beta")))
      assert_true(fields.get("reasoning_effort") is None)
    }
    _ => fail("saved settings must be an object")
  }
}

///|
async test "apply_config_option selects an effort and persists it" {
  let fs = FakeFs::new()
  let router = tk_router()
  match
    apply_config_option(
      router,
      fs,
      "/cetas-home",
      "effort",
      @acp.SessionConfigValue::ValueId("high"),
    ) {
    Ok(options) => {
      assert_eq(router.active_effort(), Some("high"))
      match tk_find_option(options, "effort") {
        Some(select) => assert_eq(select.current_value, "high")
        None => fail("effort arm missing")
      }
    }
    Err(message) => fail("effort selection must apply: " + message)
  }
  let saved = @json.parse(fs.files["/cetas-home/.cetas/settings.json"]) catch {
    _ => fail("saved settings must parse")
  }
  match saved {
    Json::Object(fields) => {
      assert_true(fields.get("model") is Some(Json::String("test/alpha")))
      assert_true(fields.get("reasoning_effort") is Some(Json::String("high")))
    }
    _ => fail("saved settings must be an object")
  }
}

///|
async test "apply_config_option rejects unknown ids and invalid values" {
  let fs = FakeFs::new()
  let router = tk_router()
  match
    apply_config_option(
      router,
      fs,
      "/cetas-home",
      "model",
      @acp.SessionConfigValue::ValueId("gone/x"),
    ) {
    Err(message) => assert_true(message.contains("unknown model slot"))
    Ok(_) => fail("unknown slot must be rejected")
  }
  match
    apply_config_option(
      router,
      fs,
      "/cetas-home",
      "effort",
      @acp.SessionConfigValue::ValueId("turbo"),
    ) {
    Err(message) => assert_true(message.contains("unsupported effort"))
    Ok(_) => fail("unsupported effort must be rejected")
  }
  router.switch_slot("test/beta")
  match
    apply_config_option(
      router,
      fs,
      "/cetas-home",
      "effort",
      @acp.SessionConfigValue::ValueId("low"),
    ) {
    Err(message) => assert_true(message.contains("unsupported effort"))
    Ok(_) => fail("slot without efforts must reject effort selection")
  }
  match
    apply_config_option(
      router,
      fs,
      "/cetas-home",
      "mode",
      @acp.SessionConfigValue::ValueId("plan"),
    ) {
    Err(message) => assert_true(message.contains("unknown config option"))
    Ok(_) => fail("unknown config id must be rejected")
  }
  match
    apply_config_option(
      router,
      fs,
      "/cetas-home",
      "model",
      @acp.SessionConfigValue::Boolean(true),
    ) {
    Err(message) => assert_true(message.contains("value id"))
    Ok(_) => fail("boolean payload must be rejected")
  }
  // Rejected calls never touch the settings file.
  assert_false(fs.files.contains("/cetas-home/.cetas/settings.json"))
}

///|
async test "apply_config_option tolerates a persistence failure" {
  let fs = FakeFs::new()
  fs.fail_writes = true
  fs.files["/cetas-home/.cetas/settings.json"] = "{}"
  let router = tk_router()
  match
    apply_config_option(
      router,
      fs,
      "/cetas-home",
      "model",
      @acp.SessionConfigValue::ValueId("test/beta"),
    ) {
    Ok(_) => assert_eq(router.active_slot_id(), "test/beta")
    Err(message) => fail("persistence failure must not reject: " + message)
  }
  // The failed atomic write left the original content untouched.
  assert_eq(fs.files["/cetas-home/.cetas/settings.json"], "{}")
}

///|
async test "set_config_option switches, persists, and pushes an update" {
  let fs = FakeFs::new()
  fs.files["/cetas-home/.cetas/settings.json"] = "{}"
  let (host, _) = tk_host([], fs~)
  let client = FakeAcpClient::FakeAcpClient()
  let result = host.handle_set_config_option(fake_acp_context(client), {
    session_id: "cetas-1",
    config_id: "model",
    value: @acp.SessionConfigValue::ValueId("test/beta"),
    meta: Omitted,
  })
  assert_eq(host.router.active_slot_id(), "test/beta")
  match tk_find_option(result.config_options, "model") {
    Some(select) => assert_eq(select.current_value, "test/beta")
    None => fail("model arm missing")
  }
  let saved = @json.parse(fs.files["/cetas-home/.cetas/settings.json"]) catch {
    _ => fail("saved settings must parse")
  }
  assert_true(
    saved is Json::Object(fields) &&
    fields.get("model") is Some(Json::String("test/beta")),
  )
  let mut saw_update = false
  for frame in client.sent {
    match frame.update {
      ConfigOptionUpdate(_) => saw_update = true
      _ => ()
    }
  }
  assert_true(saw_update)
  // Invalid values reject the request without touching the router.
  let rejected : Result[@acp.SetSessionConfigOptionResult, @acp.HandlerError] = Ok(
    host.handle_set_config_option(fake_acp_context(client), {
      session_id: "cetas-1",
      config_id: "model",
      value: @acp.SessionConfigValue::ValueId("gone/x"),
      meta: Omitted,
    }),
  ) catch {
    error => Err(error)
  }
  match rejected {
    // Invalid values reject with a typed application error carrying the
    // reason, not a silent failure.
    Err(Application(message~)) =>
      assert_true(message.contains("unknown model slot"))
    _ => fail("expected an application error")
  }
  assert_eq(host.router.active_slot_id(), "test/beta")
}

// --------------------------------------------------------- lazy model refresh

///|
async test "the model cache seeds the native assembly's router slots" {
  let fs = FakeFs::new()
  fs.files["/cetas-home/.cetas/settings.json"] = "{\"providers\":{\"opencode\":{\"api_key\":\"sk-zen-test\"}}}"
  fs.files["/cetas-home/.cetas/model_lists.json"] = "{\"opencode\":[{\"model_id\":\"claude-sonnet-5\",\"thinking_efforts\":[],\"default_effort\":null,\"context_window\":null},{\"model_id\":\"gpt-5.1-codex\",\"thinking_efforts\":[],\"default_effort\":null,\"context_window\":null}]}"
  let bridge = @ext_acp.AcpBridge::new()
  let (_agent, router, _refreshables, _snapshot) = build_native_agent(
    home="/cetas-home",
    cwd="/",
    bridge,
    fs,
    mcp_group=None,
    mcp_mode=@mcp.LoadMode::Lazy,
  ) catch {
    error => fail("native assembly must succeed: " + error.to_string())
  }
  // The cached zen records expand into full slots at composition time — no
  // network, no refresh — so session/new announces the complete list.
  assert_eq(router.list_slot_ids(), [
    "opencode/claude-sonnet-5", "opencode/gpt-5.1-codex",
  ])
}

///|
async test "an unreadable model cache degrades to the static single slot" {
  let fs = FakeFs::new()
  fs.files["/cetas-home/.cetas/settings.json"] = "{\"providers\":{\"opencode\":{\"api_key\":\"sk-zen-test\"}}}"
  fs.files["/cetas-home/.cetas/model_lists.json"] = "{corrupt"
  let bridge = @ext_acp.AcpBridge::new()
  let (_agent, router, _refreshables, _snapshot) = build_native_agent(
    home="/cetas-home",
    cwd="/",
    bridge,
    fs,
    mcp_group=None,
    mcp_mode=@mcp.LoadMode::Lazy,
  ) catch {
    error => fail("a corrupt cache must never fail composition")
  }
  assert_eq(router.list_slot_ids(), ["opencode/claude-sonnet-5"])
}

///|
async test "refresh_model_lists swaps router slots, persists the cache, and pushes updates" {
  let fs = FakeFs::new()
  let refreshed = @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id="test",
    slots=[
      tk_router_slot("test/alpha", "Alpha", ["low", "high"]),
      tk_router_slot("test/gamma", "Gamma", []),
      tk_router_slot("test/delta", "Delta", []),
    ],
  )
  let factory : &@llm.RefreshableProviderFactory = FakeRefreshFactory::{
    fixed_id: "test",
    catalog: refreshed,
  }
  let (host, _) = tk_host([], fs~, refreshables=[factory])
  let client = FakeAcpClient::FakeAcpClient()
  let session = host.handle_new_session(
    fake_acp_context(client),
    tk_new_session_params(),
  )
  // Before the refresh the announcement carries the composed two slots.
  assert_eq(host.router.list_slot_ids(), ["test/alpha", "test/beta"])
  host.refresh_model_lists()
  // After the refresh the provider's slots are hot-swapped (beta replaced),
  // the projected records are on disk, and every live session received one
  // config_option_update carrying the new options.
  assert_eq(host.router.list_slot_ids(), [
    "test/alpha", "test/gamma", "test/delta",
  ])
  match fs.files.get("/cetas-home/.cetas/model_lists.json") {
    Some(text) => {
      assert_true(text.contains("gamma"))
      assert_true(text.contains("delta"))
    }
    None => fail("refresh must persist the model cache")
  }
  assert_eq(client.sent.length(), 1)
  match client.sent[0].update {
    @acp.SessionUpdate::ConfigOptionUpdate({ config_options, .. }) =>
      match tk_find_option(config_options, "model") {
        Some(select) =>
          assert_eq(tk_ungrouped(select.options).length(), 3) catch {
            _ => fail("model option must stay an ungrouped select")
          }
        None => fail("pushed options must include the model arm")
      }
    _ => fail("expected a config option update")
  }
  assert_eq(session.session_id, "cetas-1")
}

///|
async test "a failing refresh keeps the current slots and pushes nothing" {
  let fs = FakeFs::new()
  let factory : &@llm.RefreshableProviderFactory = FailingRefreshFactory::{
    fixed_id: "test",
  }
  let (host, _) = tk_host([], fs~, refreshables=[factory])
  let client = FakeAcpClient::FakeAcpClient()
  let _session = host.handle_new_session(
    fake_acp_context(client),
    tk_new_session_params(),
  )
  host.refresh_model_lists()
  assert_eq(host.router.list_slot_ids(), ["test/alpha", "test/beta"])
  assert_false(fs.files.contains("/cetas-home/.cetas/model_lists.json"))
  assert_eq(client.sent.length(), 0)
}
