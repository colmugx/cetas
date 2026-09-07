///|
// ---------------------------------------------------------------- fixtures

///|
priv struct FakeAcpClient {
  sent : Array[@acp.SessionUpdateParams]
  asked : Array[@acp.RequestPermissionRequest]
  reply : @acp.RequestPermissionResponse
  /// Served by fs reverse calls; only when `fs_enabled`, else they fail like wire errors.
  files : Map[String, String]
  fs_reads : Array[@acp.ReadTextFileParams]
  fs_writes : Array[@acp.WriteTextFileParams]
  mut fs_enabled : Bool
}

///|
fn FakeAcpClient::FakeAcpClient(
  reply? : @acp.RequestPermissionResponse = {
    outcome: Selected({ option_id: @ext_acp.ACP_ALLOW_ONCE, meta: Omitted, }),
    meta: Omitted,
  },
) -> FakeAcpClient {
  {
    sent: [],
    asked: [],
    reply,
    files: Map::from_array([]),
    fs_reads: [],
    fs_writes: [],
    fs_enabled: false,
  }
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
        FsReadTextFile(params) => {
          client.fs_reads.push(params)
          if client.fs_enabled {
            match client.files.get(params.path) {
              Some(content) =>
                Ok(AgentReplyFsReadTextFile({ content, meta: Omitted, }))
              None =>
                Err(AgentContextBrokerFailure(method_name="fs/read_text_file"))
            }
          } else {
            Err(AgentContextBrokerFailure(method_name="fs/read_text_file"))
          }
        }
        FsWriteTextFile(params) => {
          client.fs_writes.push(params)
          if client.fs_enabled {
            client.files[params.path] = params.content
            Ok(AgentReplyFsWriteTextFile({ meta: Omitted, }))
          } else {
            Err(AgentContextBrokerFailure(method_name="fs/write_text_file"))
          }
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
fn tk_prompt(text : String) -> Array[@acp.ContentBlock] {
  [Text({ annotations: Omitted, text, meta: Omitted, })]
}

///|
priv struct FakeFs {
  files : Map[String, String]
  mut fail_writes : Bool
  mut fail_removes : Bool
}

///|
fn FakeFs::FakeFs() -> FakeFs {
  { files: Map::from_array([]), fail_writes: false, fail_removes: false, }
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
  if self.fail_removes {
    raise @workspace.WorkspaceFsError::WorkspaceFsError("remove failed")
  }
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
fn tk_router_slot(
  id : String,
  label : String,
  efforts : Array[String],
  context_window? : Int? = None,
) -> @llm.ModelSlot {
  let base : @llm.ModelSlot = @llm.ModelSlot::ModelSlot(
    id~,
    label~,
    provider_id="test",
    model_id=id,
    port=@posoco.ScriptedModel([]),
    thinking_efforts=efforts,
    context_window~,
    default_effort=if efforts.is_empty() { None } else { Some(efforts[0]) },
  )
  {
    ..base,
    rebuild_on_effort: Some(effort => { ..base, default_effort: Some(effort), }),
  }
}

///|
fn tk_router() -> @llm.RouterModelPort raise @posoco.CompositionError {
  @llm.RouterModelPort(slots=[
    tk_router_slot("test/alpha", "Alpha", ["low", "high"]),
    tk_router_slot("test/beta", "Beta", []),
  ])
}

///|
/// Production session factory in miniature; `store` swaps persistence onto a real JSONL store.
fn tk_spawn_session(
  model : &@posoco.ModelPort,
  tools : @posoco.RecordingToolProvider,
  process_cwd : String,
  store? : &@posoco.SessionStore? = None,
  context_window? : Int? = None,
) -> async (String, @acp.NewSessionParams) -> Result[SessionHandle, String] {
  fn(
    _session_id : String,
    params : @acp.NewSessionParams,
  ) -> Result[SessionHandle, String] {
    let cwd = if params.cwd.length() > 0 { params.cwd } else { process_cwd }
    let sessions : Array[&@posoco.SessionStore] = match store {
      Some(real) => [real]
      None => [@posoco.RecordingSessionStore::RecordingSessionStore()]
    }
    try {
      let bridge = @ext_acp.AcpBridge(context_window~)
      let policy = @permission.PermissionPolicy(
        @permission.WorkspaceWrite,
        approval=Some(bridge as &@permission.ApprovalSource),
      )
      let agent = @posoco.Agent(
        exts=[
          @posoco.tk_ext(id="model", model=Some(model)),
          @posoco.tk_ext(id="tools", tools=[tools]),
          @posoco.tk_ext(id="io", sessions~),
          bridge,
          policy,
        ],
        config=@posoco.tk_config(),
      )
      Ok({
        bridge,
        router: tk_router(),
        agent,
        cwd,
        plan: @plan.PlanMode(),
        permission: policy,
        fs_delegate: None,
        context: None,
        in_flight: None,
        turn_lock: @async.Mutex::Mutex(),
        last_mode_id: "default",
      })
    } catch {
      error => Err(error.to_string())
    }
  }
}

///|
/// Host over a shared scripted model (steps consumed in call order); `store` wires a real JSONL root.
fn tk_host(
  steps : Array[@posoco.ScriptedModelStep],
  tools? : @posoco.RecordingToolProvider = @posoco.RecordingToolProvider(
    [],
    Map::from_array([]),
  ),
  fs? : FakeFs = FakeFs(),
  refreshables? : Array[&@llm.RefreshableProviderFactory] = [],
  process_cwd? : String = "/",
  store? : @fs_session.JsonlSessionStore,
  wire_log? : Bool = false,
  context_window? : Int? = None,
) -> (CetasAcpHost, @posoco.ScriptedModel) {
  let model = @posoco.ScriptedModel(steps)
  let spawn = match store {
    Some(real) =>
      tk_spawn_session(
        model,
        tools,
        process_cwd,
        store=Some(real as &@posoco.SessionStore),
        context_window~,
      )
    None => tk_spawn_session(model, tools, process_cwd, context_window~)
  }
  let host_store = match store {
    Some(real) => real
    None => @fs_session.JsonlSessionStore("/cetas-home/.cetas/sessions")
  }
  (
    CetasAcpHost::of(
      spawn_session=spawn,
      home="/cetas-home",
      fs~,
      refreshables~,
      session_store=host_store,
      process_cwd~,
      wire_log~,
    ),
    model,
  )
}

///|
fn tk_host_model(model : &@posoco.ModelPort) -> CetasAcpHost {
  CetasAcpHost::of(
    spawn_session=tk_spawn_session(
      model,
      @posoco.RecordingToolProvider([], Map::from_array([])),
      "/",
    ),
    home="/cetas-home",
    fs=FakeFs(),
  )
}

///|
/// Plan wiring in miniature: plan mode and the permission policy share one bus (tools bypass asks).
fn tk_spawn_session_plan(
  model : &@posoco.ModelPort,
  process_cwd : String,
) -> async (String, @acp.NewSessionParams) -> Result[SessionHandle, String] {
  fn(
    _session_id : String,
    params : @acp.NewSessionParams,
  ) -> Result[SessionHandle, String] {
    let cwd = if params.cwd.length() > 0 { params.cwd } else { process_cwd }
    try {
      let bridge = @ext_acp.AcpBridge()
      let event_bus = @devkit.EventBus()
      let policy = @permission.PermissionPolicy(
        @permission.WorkspaceWrite,
        approval=Some(bridge as &@permission.ApprovalSource),
        bus=Some(event_bus),
      )
      let plan_mode = @plan.PlanMode(
        config={
          ..@plan.PlanModeConfig::default()
          // ask_question rides the permission read class.
          ,
          allowed_tools: ["read", "glob", "grep", "ask_question"],
          allow_model_entry: true,
        },
        review=Some(AcpPlanReview::{ bridge, } as &@plan.PlanReviewSource),
        bus=Some(event_bus),
      )
      let agent = @posoco.Agent(
        exts=[
          @posoco.tk_ext(id="model", model=Some(model)),
          @posoco.tk_ext(id="io", sessions=[
            @posoco.RecordingSessionStore::RecordingSessionStore()
            as &@posoco.SessionStore,
          ]),
          bridge,
          policy,
          plan_mode,
        ],
        config=@posoco.tk_config(),
      )
      Ok({
        bridge,
        router: tk_router(),
        agent,
        cwd,
        plan: plan_mode,
        permission: policy,
        fs_delegate: None,
        context: None,
        in_flight: None,
        turn_lock: @async.Mutex::Mutex(),
        last_mode_id: "default",
      })
    } catch {
      error => Err(error.to_string())
    }
  }
}

///|
fn tk_host_plan(
  steps : Array[@posoco.ScriptedModelStep],
) -> (CetasAcpHost, @posoco.ScriptedModel) {
  let model = @posoco.ScriptedModel(steps)
  let host = CetasAcpHost::of(
    spawn_session=tk_spawn_session_plan(model, "/"),
    home="/cetas-home",
    fs=FakeFs(),
  )
  (host, model)
}

///|
fn tk_plan_reply(option_id : String) -> @acp.RequestPermissionResponse {
  { outcome: Selected({ option_id, meta: Omitted, }), meta: Omitted, }
}

///|
fn tk_plan_turn(plan_text : String) -> Array[@posoco.ScriptedModelStep] {
  [
    @posoco.Respond(
      @posoco.tk_tool_call_response(
        "enter_plan_mode",
        "pe1",
        Json::object(Map::from_array([])),
      ),
    ),
    @posoco.Respond(
      @posoco.tk_tool_call_response(
        "exit_plan_mode",
        "px1",
        Json::object(
          Map::from_array([
            ("name", Json::string("my plan")),
            ("plan", Json::string(plan_text)),
          ]),
        ),
      ),
    ),
    @posoco.Respond(@posoco.tk_stop_response("planning resolved")),
  ]
}

///|
async fn tk_open_session(host : CetasAcpHost, client : FakeAcpClient) -> String {
  let result = host.handle_new_session(
    fake_acp_context(client),
    tk_new_session_params(),
  )
  result.session_id
}

///|
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
  _self : FailingRefreshFactory,
  _source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  raise @posoco.CompositionError::ManifestSchemaError(
    manifest_id="fake-refresh",
    detail="offline",
  )
}

///|
fn tk_new_session_params(
  cwd? : String = "/",
  mcp_servers? : Array[@acp.McpServer] = [],
) -> @acp.NewSessionParams {
  { cwd, additional_directories: Omitted, mcp_servers, meta: Omitted, }
}

///|
fn tk_load_params(
  session_id : String,
  cwd? : String = "/",
  mcp_servers? : Array[@acp.McpServer] = [],
) -> @acp.LoadSessionParams {
  {
    mcp_servers,
    cwd,
    additional_directories: Omitted,
    session_id,
    meta: Omitted,
  }
}

///|
fn tk_resume_params(
  session_id : String,
  cwd? : String = "/",
) -> @acp.ResumeSessionParams {
  {
    session_id,
    cwd,
    additional_directories: Omitted,
    mcp_servers: Omitted,
    meta: Omitted,
  }
}

///|
/// Unique per label + millisecond, so parallel tests never share a root.
fn tk_temp_root(label : String) -> String {
  let base = match @env.get_env_var("TMPDIR") {
    Some(dir) => if dir.length() > 0 { dir } else { "/tmp" }
    None => "/tmp"
  }
  let joined = if base.has_suffix("/") { base } else { base + "/" }
  joined + "cetas-w4-" + label + "-" + @async.now().to_string()
}

///|
fn tk_env(name : String, value : String) -> @acp.McpEnvVariable {
  { name, value, meta: Omitted, }
}

///|
fn tk_header(name : String, value : String) -> @acp.McpHttpHeader {
  { name, value, meta: Omitted, }
}

// ------------------------------------------------------------ prompt input

///|
test "acp_prompt_to_message maps text image and resource link" {
  let message = acp_prompt_to_message([
    Text({ annotations: Omitted, text: "hello", meta: Omitted, }),
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
fn tk_durable_id_shape(id : String) -> Bool {
  if !id.has_prefix("cetas-") {
    return false
  }
  let tail = id.sub(start=6).to_owned()
  if tail.length() == 0 {
    return false
  }
  let mut ok = true
  for char in tail {
    match char {
      '0' | '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9' | '-' => ()
      _ => ok = false
    }
  }
  ok
}

///|
async test "session ids are clock-minted, validator-clean, and unique within and across hosts" {
  let (host_a, _) = tk_host([])
  let (host_b, _) = tk_host([])
  let ids : Array[String] = []
  for i = 0; i < 8; i = i + 1 {
    let host = if i % 2 == 0 { host_a } else { host_b }
    ids.push(
      host.handle_new_session(
        fake_acp_context(FakeAcpClient::FakeAcpClient()),
        tk_new_session_params(),
      ).session_id,
    )
  }
  for i = 0; i < ids.length(); i = i + 1 {
    assert_true(tk_durable_id_shape(ids[i]))
    // The id doubles as a JSONL file stem, so it must pass the store's filename check.
    assert_true(@fs_session.validate_session_id(ids[i]) is Ok(_))
    for j = i + 1; j < ids.length(); j = j + 1 {
      assert_false(ids[i] == ids[j])
    }
  }
}

// ------------------------------------------------------------------ prompt

///|
async test "prompt streams the assistant message and ends the turn" {
  let (host, _) = tk_host([
    @posoco.Respond(@posoco.tk_stop_response("hi there")),
  ])
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let result = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt("hello"),
    meta: Omitted,
  })
  assert_true(result.stop_reason is EndTurn)
  assert_true(client.sent.length() >= 1)
  assert_eq(client.sent[0].session_id, session_id)
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
/// `tk_stop_response` carries no usage; this one reports `total` tokens so
/// the bridge's UsageUpdate path runs.
fn tk_stop_response_used(text : String, total : Int) -> @posoco.ModelCallResult {
  {
    completion: @posoco.Completion::Completion(
      content=[@posoco.Content::Text(text)],
      tool_calls=[],
      reasoning=None,
      finish_reason=@posoco.FinishReason::Stop,
      usage=Some({
        input_tokens: Some(total - 1),
        output_tokens: Some(1),
        total_tokens: Some(total),
        cached_input_tokens: None,
        uncached_input_tokens: None,
      }),
    ),
    processed_messages: [],
  }
}

///|
async test "prompt usage update carries the host context window as size" {
  let (host, _) = tk_host(
    [@posoco.Respond(tk_stop_response_used("hi there", 10))],
    context_window=Some(200000),
  )
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let result = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt("hello"),
    meta: Omitted,
  })
  assert_true(result.stop_reason is EndTurn)
  let mut saw_usage = false
  for frame in client.sent {
    match frame.update {
      UsageUpdate(usage) => {
        assert_eq(usage.used, 10)
        assert_eq(usage.size, 200000)
        saw_usage = true
      }
      _ => ()
    }
  }
  assert_true(saw_usage)
}

///|
async test "active slot's declared context window is the bridge's size source" {
  let router = @llm.RouterModelPort(slots=[
    tk_router_slot("test/alpha", "Alpha", [], context_window=Some(128000)),
    tk_router_slot("test/beta", "Beta", []),
  ])
  assert_eq(active_slot_context_window(router), Some(128000))
  // Following a model switch the window tracks the new active slot; a slot
  // without a declared window yields None (bridge keeps size 0).
  router.switch_slot("test/beta") catch {
    error => fail("switch_slot must succeed: " + error.to_string())
  }
  assert_eq(active_slot_context_window(router), None)
}

///|
async test "prompt rejects an unknown session id" {
  let (host, _) = tk_host([
    @posoco.Respond(@posoco.tk_stop_response("hi there")),
  ])
  let outcome : Result[@acp.PromptResult, @acp.HandlerError] = Ok(
    host.handle_prompt(fake_acp_context(FakeAcpClient::FakeAcpClient()), {
      session_id: "cetas-404",
      prompt: tk_prompt("hello"),
      meta: Omitted,
    }),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Ok(_) => fail("unknown session must reject the prompt")
    Err(InvalidParams(message~)) =>
      assert_true(message.contains("unknown session"))
    Err(_) => fail("expected an invalid-params error")
  }
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
  let session_id = tk_open_session(host, client)
  let result = host.handle_prompt(fake_acp_context(client), {
    session_id,
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
  assert_eq(client.asked.length(), 1)
  assert_eq(client.asked[0].session_id, session_id)
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
    outcome: Selected({ option_id: @ext_acp.ACP_REJECT_ONCE, meta: Omitted, }),
    meta: Omitted,
  })
  let session_id = tk_open_session(host, client)
  let outcome : Result[@acp.PromptResult, @acp.HandlerError] = Ok(
    host.handle_prompt(fake_acp_context(client), {
      session_id,
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
  let (host, _) = tk_host([])
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let outcome : Result[@acp.PromptResult, @acp.HandlerError] = Ok(
    host.handle_prompt(fake_acp_context(FakeAcpClient::FakeAcpClient()), {
      session_id,
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

// ------------------------------------------------------------- plan review

///|
async test "plan review asks with named options and approve exits plan mode" {
  // 120 chars: the title must truncate while raw_input carries the full plan.
  let long_plan = Array::make(12, "abcdefghij").join("")
  let (host, _) = tk_host_plan(tk_plan_turn(long_plan))
  let client = FakeAcpClient::FakeAcpClient(
    reply=tk_plan_reply(PLAN_OPTION_APPROVE),
  )
  let session_id = tk_open_session(host, client)
  let result = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt("plan something"),
    meta: Omitted,
  })
  assert_true(result.stop_reason is EndTurn)
  // Exactly one ask: the plan review — enter/exit tools are bus-exempt from the gate.
  assert_eq(client.asked.length(), 1)
  let ask = client.asked[0]
  assert_eq(ask.session_id, session_id)
  assert_eq(ask.tool_call.tool_call_id, "plan-review")
  assert_true(ask.tool_call.kind is Value(Other))
  assert_eq(ask.options.length(), 3)
  assert_eq(ask.options[0].option_id, PLAN_OPTION_APPROVE)
  assert_eq(ask.options[0].name, "Approve plan")
  assert_true(ask.options[0].kind is AllowOnce)
  assert_eq(ask.options[1].option_id, PLAN_OPTION_KEEP_PLANNING)
  assert_eq(ask.options[1].name, "Keep planning")
  assert_true(ask.options[1].kind is RejectOnce)
  assert_eq(ask.options[2].option_id, PLAN_OPTION_AUTO_EDIT)
  assert_eq(ask.options[2].name, "Auto-edit (approve & stop asking)")
  assert_true(ask.options[2].kind is AllowAlways)
  let title = match ask.tool_call.title {
    Value(title) => title
    _ => fail("tool call title missing")
  }
  assert_eq(title.length(), 80)
  assert_true(title.has_suffix("..."))
  match ask.tool_call.raw_input {
    Value(Json::Object(fields)) =>
      match fields.get("plan") {
        Some(Json::String(plan)) => assert_eq(plan, long_plan)
        _ => fail("raw_input.plan missing")
      }
    _ => fail("raw_input missing")
  }
  match host.sessions.get(session_id) {
    Some(handle) => assert_true(handle.plan.status is Off)
    None => fail("session vanished")
  }
  let mut accepted = false
  for frame in client.sent {
    match frame.update {
      ToolCallUpdate(update) =>
        match update.content {
          Value(blocks) =>
            for block in blocks {
              match block {
                Content({ content: Text({ text, .. }), .. }) =>
                  if text.contains("Plan accepted by the user") {
                    accepted = true
                  }
                _ => ()
              }
            }
          _ => ()
        }
      _ => ()
    }
  }
  assert_true(accepted)
}

///|
async test "keep-planning returns the feedback as the tool result" {
  let (host, _) = tk_host_plan(tk_plan_turn("1. do it"))
  let client = FakeAcpClient::FakeAcpClient(
    reply=tk_plan_reply(PLAN_OPTION_KEEP_PLANNING),
  )
  let session_id = tk_open_session(host, client)
  let result = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt("plan something"),
    meta: Omitted,
  })
  assert_true(result.stop_reason is EndTurn)
  assert_eq(client.asked.length(), 1)
  match host.sessions.get(session_id) {
    Some(handle) => assert_true(handle.plan.status is Planning)
    None => fail("session vanished")
  }
  let mut delivered = false
  for frame in client.sent {
    match frame.update {
      ToolCallUpdate(update) =>
        if update.tool_call_id == "px1" {
          match update.content {
            Value(blocks) =>
              for block in blocks {
                match block {
                  Content({ content: Text({ text, .. }), .. }) =>
                    if text.contains("The user chose to keep planning") {
                      delivered = true
                    }
                  _ => ()
                }
              }
            _ => ()
          }
        }
      _ => ()
    }
  }
  assert_true(delivered)
}

///|
async test "cancelled plan review keeps planning instead of killing the turn" {
  let (host, _) = tk_host_plan(tk_plan_turn("1. do it"))
  let client = FakeAcpClient::FakeAcpClient(reply={
    outcome: Cancelled,
    meta: Omitted,
  })
  let session_id = tk_open_session(host, client)
  let result = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt("plan something"),
    meta: Omitted,
  })
  assert_true(result.stop_reason is EndTurn)
  match host.sessions.get(session_id) {
    Some(handle) => assert_true(handle.plan.status is Planning)
    None => fail("session vanished")
  }
  let mut revise = false
  let mut dismissed = false
  for frame in client.sent {
    match frame.update {
      ToolCallUpdate(update) =>
        match update.content {
          Value(blocks) =>
            for block in blocks {
              match block {
                Content({ content: Text({ text, .. }), .. }) => {
                  if text.contains("Continue planning") {
                    revise = true
                  }
                  if text.contains("turn is cancelled") {
                    dismissed = true
                  }
                }
                _ => ()
              }
            }
          _ => ()
        }
      _ => ()
    }
  }
  assert_true(revise)
  assert_false(dismissed)
}

///|
async test "auto-edit option accepts the plan" {
  let client = FakeAcpClient::FakeAcpClient(
    reply=tk_plan_reply(PLAN_OPTION_AUTO_EDIT),
  )
  let bridge = @ext_acp.AcpBridge()
  bridge.attach(context=fake_acp_context(client), session_id="s-plan-auto")
  let review = AcpPlanReview::{ bridge, }
  match
    @plan.PlanReviewSource::review(review, @plan.PlanReviewRequest::{
      plan: "1. do it",
    }) {
    Accept => assert_eq(client.asked.length(), 1)
    _ => fail("auto-edit must accept the plan")
  }
}

///|
async test "unknown plan option keeps planning with an explanation" {
  let client = FakeAcpClient::FakeAcpClient(
    reply=tk_plan_reply("mystery-option"),
  )
  let bridge = @ext_acp.AcpBridge()
  bridge.attach(context=fake_acp_context(client), session_id="s-plan-unknown")
  let review = AcpPlanReview::{ bridge, }
  match
    @plan.PlanReviewSource::review(review, @plan.PlanReviewRequest::{
      plan: "1. do it",
    }) {
    Revise(feedback~) => assert_true(feedback.contains("unrecognized"))
    _ => fail("unknown option must keep planning")
  }
  assert_eq(client.asked.length(), 1)
}

///|
async test "plan review transport failure keeps planning" {
  let client = FakeAcpClient::FakeAcpClient()
  let bridge = @ext_acp.AcpBridge()
  bridge.attach(
    context=@acp.agent_context(
      request_broker=_request => {
        Err(AgentContextBrokerFailure(method_name="session/request_permission"))
      },
      notification_broker=_notification => Ok(()),
    ),
    session_id="s-plan-fail",
  )
  let review = AcpPlanReview::{ bridge, }
  match
    @plan.PlanReviewSource::review(review, @plan.PlanReviewRequest::{
      plan: "1. do it",
    }) {
    Revise(feedback~) =>
      assert_true(feedback.contains("plan review request failed"))
    _ => fail("transport failure must keep planning")
  }
  assert_eq(client.asked.length(), 0)
}

///|
async test "plan review without an attached bridge falls back to planning" {
  let review = AcpPlanReview::{ bridge: @ext_acp.AcpBridge(), }
  match
    @plan.PlanReviewSource::review(review, @plan.PlanReviewRequest::{
      plan: "1. do it",
    }) {
    Revise(feedback~) => assert_eq(feedback, "plan review unavailable")
    _ => fail("detached bridge must keep planning")
  }
}

// -------------------------------------------------------------- cancellation

///|
async test "cancel interrupts the session's in-flight turn" {
  let (host, _) = tk_host([])
  let session_id = tk_open_session(host, FakeAcpClient::FakeAcpClient())
  @async.with_task_group(group => {
    let sleeper = group.spawn(() => {
      @async.sleep(10_000)
      let placeholder : @posoco.TurnResult = {
        message: @posoco.tk_user_msg(""),
        tool_results: [],
        final_session_id: session_id,
      }
      placeholder
    })
    host.sessions[session_id].in_flight = Some(sleeper)
    host.handle_cancel(fake_acp_context(FakeAcpClient::FakeAcpClient()), {
      session_id,
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

// -------------------------------------------------------------------- close

///|
/// Chat parks until close cancels it; `interrupted` records the cut-short park.
priv struct SlowModel {
  response : String
  mut interrupted : Bool
}

///|
impl @posoco.ModelPort for SlowModel with fn chat(
  self,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  @async.sleep(120_000) catch {
    error => {
      self.interrupted = @async.is_cancellation_error(error)
      raise @posoco.ModelError::Transport(
        "slow model interrupted: " + error.to_string(),
      )
    }
  }
  @posoco.tk_stop_response(self.response)
}

///|
impl @posoco.ModelPort for SlowModel with fn compact(
  _self,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "SlowModel does not implement compact",
  )
}

///|
impl @posoco.ModelPort for SlowModel with fn provider_config(_self) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
async test "close retires the session and later prompts reject as unknown" {
  let (host, _) = tk_host([
    @posoco.Respond(@posoco.tk_stop_response("hi")),
    @posoco.Respond(@posoco.tk_stop_response("hi")),
  ])
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let before = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt("hello"),
    meta: Omitted,
  })
  assert_true(before.stop_reason is EndTurn)
  let closed = host.handle_close(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    { session_id, meta: Omitted, },
  )
  assert_true(closed.meta is Omitted)
  let rejected : Result[@acp.PromptResult, @acp.HandlerError] = Ok(
    host.handle_prompt(fake_acp_context(client), {
      session_id,
      prompt: tk_prompt("again"),
      meta: Omitted,
    }),
  ) catch {
    error => Err(error)
  }
  match rejected {
    Ok(_) => fail("a closed session must reject prompts")
    Err(InvalidParams(message~)) =>
      assert_true(message.contains("unknown session"))
    Err(_) => fail("expected an invalid-params error")
  }
}

///|
async test "close on an unknown session is a silent no-op" {
  let (host, _) = tk_host([])
  let result = host.handle_close(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    { session_id: "cetas-never-minted", meta: Omitted, },
  )
  assert_true(result.meta is Omitted)
}

///|
async test "close cancels and drains an in-flight turn, then retires the session" {
  let model = SlowModel::{ response: "too late", interrupted: false, }
  let model_port : &@posoco.ModelPort = model
  let host = tk_host_model(model_port)
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  @async.with_task_group(group => {
    // An interrupted turn may settle through either channel (result or error).
    let prompt_task = group.spawn(
      () => {
        host.handle_prompt(fake_acp_context(client), {
          session_id,
          prompt: tk_prompt("slow work"),
          meta: Omitted,
        })
      },
      allow_failure=true,
    )
    let mut in_flight = false
    while !in_flight {
      @async.pause()
      in_flight = host.sessions[session_id].in_flight is Some(_)
    }
    ignore(
      host.handle_close(fake_acp_context(FakeAcpClient::FakeAcpClient()), {
        session_id,
        meta: Omitted,
      }),
    )
    assert_true(model.interrupted)
    let settled : Result[@acp.PromptResult, Error] = Ok(prompt_task.wait()) catch {
      error => Err(error)
    }
    match settled {
      Ok(result) => assert_true(result.stop_reason is Cancelled)
      Err(_) => ()
    }
    let rejected : Result[@acp.PromptResult, @acp.HandlerError] = Ok(
      host.handle_prompt(fake_acp_context(client), {
        session_id,
        prompt: tk_prompt("again"),
        meta: Omitted,
      }),
    ) catch {
      error => Err(error)
    }
    match rejected {
      Ok(_) => fail("the retired session must reject prompts")
      Err(InvalidParams(message~)) =>
        assert_true(message.contains("unknown session"))
      Err(_) => fail("expected an invalid-params error")
    }
  })
}

///|
async test "repeated new/close cycles leave no sessions behind" {
  let (host, _) = tk_host([])
  let retired : Array[String] = []
  for _i = 0; _i < 8; _i = _i + 1 {
    let id = tk_open_session(host, FakeAcpClient::FakeAcpClient())
    ignore(
      host.handle_close(fake_acp_context(FakeAcpClient::FakeAcpClient()), {
        session_id: id,
        meta: Omitted,
      }),
    )
    retired.push(id)
  }
  assert_eq(host.snapshot_sessions().length(), 0)
  for id in retired {
    let rejected : Result[@acp.PromptResult, @acp.HandlerError] = Ok(
      host.handle_prompt(fake_acp_context(FakeAcpClient::FakeAcpClient()), {
        session_id: id,
        prompt: tk_prompt("hello"),
        meta: Omitted,
      }),
    ) catch {
      error => Err(error)
    }
    match rejected {
      Ok(_) => fail("a retired session must reject prompts")
      Err(InvalidParams(message~)) =>
        assert_true(message.contains("unknown session"))
      Err(_) => fail("expected an invalid-params error")
    }
  }
}

///|
async test "close tears the bridge down through the agent's lifecycle shutdown" {
  let (host, _) = tk_host([@posoco.Respond(@posoco.tk_stop_response("hi"))])
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let _ = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt("hello"),
    meta: Omitted,
  })
  // The handle outlives its map entry (struct reference), so the bridge stays inspectable.
  let handle = host.sessions[session_id]
  assert_true(handle.bridge.session_id() is Some(_))
  ignore(
    host.handle_close(fake_acp_context(FakeAcpClient::FakeAcpClient()), {
      session_id,
      meta: Omitted,
    }),
  )
  // Agent::shutdown ran the bridge's on_shutdown (ext-acp detach contract).
  assert_true(handle.bridge.session_id() is None)
}

// ----------------------------------------------------------- config options

///|
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
    tk_new_session_params(),
  )
  guard result.config_options is Value(options) else {
    fail("config options must be advertised")
  }
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
  let handle = host.sessions[result.session_id]
  handle.router.switch_slot("test/beta")
  let switched = build_config_options(handle.router, handle.permission.mode)
  assert_true(tk_find_option(switched, "model") is Some(_))
  assert_true(tk_find_option(switched, "effort") is None)
}

///|
async test "apply_config_option switches the model and persists flat keys" {
  let fs = FakeFs()
  fs.files["/cetas-home/.cetas/settings.json"] = "{\"providers\":{\"kimi\":{}}}"
  let router = tk_router()
  let policy = @permission.PermissionPolicy(@permission.WorkspaceWrite)
  match
    apply_config_option(
      router,
      policy,
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
  let fs = FakeFs()
  let router = tk_router()
  let policy = @permission.PermissionPolicy(@permission.WorkspaceWrite)
  match
    apply_config_option(
      router,
      policy,
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
  let fs = FakeFs()
  let router = tk_router()
  let policy = @permission.PermissionPolicy(@permission.WorkspaceWrite)
  match
    apply_config_option(
      router,
      policy,
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
      policy,
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
      policy,
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
      policy,
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
      policy,
      fs,
      "/cetas-home",
      "model",
      @acp.SessionConfigValue::Boolean(true),
    ) {
    Err(message) => assert_true(message.contains("value id"))
    Ok(_) => fail("boolean payload must be rejected")
  }
  assert_false(fs.files.contains("/cetas-home/.cetas/settings.json"))
}

///|
async test "apply_config_option tolerates a persistence failure" {
  let fs = FakeFs()
  fs.fail_writes = true
  fs.files["/cetas-home/.cetas/settings.json"] = "{}"
  let router = tk_router()
  let policy = @permission.PermissionPolicy(@permission.WorkspaceWrite)
  match
    apply_config_option(
      router,
      policy,
      fs,
      "/cetas-home",
      "model",
      @acp.SessionConfigValue::ValueId("test/beta"),
    ) {
    Ok(_) => assert_eq(router.active_slot_id(), "test/beta")
    Err(message) => fail("persistence failure must not reject: " + message)
  }
  assert_eq(fs.files["/cetas-home/.cetas/settings.json"], "{}")
}

///|
async test "set_config_option switches, persists, and pushes an update" {
  let fs = FakeFs()
  fs.files["/cetas-home/.cetas/settings.json"] = "{}"
  let (host, _) = tk_host([], fs~)
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let result = host.handle_set_config_option(fake_acp_context(client), {
    session_id,
    config_id: "model",
    value: @acp.SessionConfigValue::ValueId("test/beta"),
    meta: Omitted,
  })
  assert_eq(host.sessions[session_id].router.active_slot_id(), "test/beta")
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
  let rejected : Result[@acp.SetSessionConfigOptionResult, @acp.HandlerError] = Ok(
    host.handle_set_config_option(fake_acp_context(client), {
      session_id,
      config_id: "model",
      value: @acp.SessionConfigValue::ValueId("gone/x"),
      meta: Omitted,
    }),
  ) catch {
    error => Err(error)
  }
  match rejected {
    Err(Application(message~)) =>
      assert_true(message.contains("unknown model slot"))
    _ => fail("expected an application error")
  }
  assert_eq(host.sessions[session_id].router.active_slot_id(), "test/beta")
}

// ------------------------------------------------------- permission option

///|
async test "new session advertises the permission option at the default posture" {
  let (host, _) = tk_host([])
  let result = host.handle_new_session(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    tk_new_session_params(),
  )
  guard result.config_options is Value(options) else {
    fail("config options must be advertised")
  }
  match tk_find_option(options, "permission") {
    Some(select) => {
      assert_eq(select.current_value, "workspace_write")
      let listed = tk_ungrouped(select.options)
      assert_eq(listed.length(), 4)
      assert_true(listed[0] is { value: "readonly", .. })
      assert_true(listed[1] is { value: "workspace_write", .. })
      assert_true(listed[2] is { value: "interactive", .. })
      assert_true(listed[3] is { value: "yolo", .. })
    }
    None => fail("permission arm missing")
  }
}

///|
/// No test mutates process env (parallel async tests); resolution runs via the raw-value/FFI seams.
async test "startup permission posture defaults to workspace_write and validates overrides" {
  assert_true(resolve_startup_permission_mode(None) is WorkspaceWrite)
  assert_true(resolve_startup_permission_mode(Some("readonly")) is ReadOnly)
  assert_true(
    resolve_startup_permission_mode(Some("workspace_write")) is WorkspaceWrite,
  )
  assert_true(
    resolve_startup_permission_mode(Some("interactive")) is Interactive,
  )
  assert_true(resolve_startup_permission_mode(Some("yolo")) is Yolo)
  assert_true(
    resolve_startup_permission_mode(Some("sometimes")) is WorkspaceWrite,
  )
  assert_true(resolve_startup_permission_mode(Some("")) is WorkspaceWrite)
  assert_eq(permission_mode_value(ReadOnly), "readonly")
  assert_eq(permission_mode_value(WorkspaceWrite), "workspace_write")
  assert_eq(permission_mode_value(Interactive), "interactive")
  assert_eq(permission_mode_value(Yolo), "yolo")
  assert_true(read_env_var("PATH") is Some(_))
  assert_true(read_env_var("CETAS_PERMISSION_MODE_PROBE_UNSET") is None)
}

///|
/// CETAS_GOAL arms the personal goal runner; the raw-value seam substitutes
/// for the untestable process env (see the convention above).
async test "goal_ext_from_env arms goal_update_plan on a non-empty condition and degrades on blank or unset" {
  match goal_ext_from_env(Some("make the build green")) {
    Some(runner) => {
      assert_eq(runner.extension_id(), "posoco_ext_goal")
      let defs = @posoco.ToolProvider::list_tools(runner)
      assert_eq(defs.length(), 1)
      assert_eq(defs[0].name.to_string(), "goal_update_plan")
    }
    None => fail("a non-empty CETAS_GOAL must arm the goal runner")
  }
  assert_true(goal_ext_from_env(None) is None)
  assert_true(goal_ext_from_env(Some("   ")) is None)
}

///|
async test "set_config_option permission yolo stops asking for write-class calls" {
  let tools = @posoco.RecordingToolProvider(
    [@posoco.tk_tool_def("edit", "edit a file")],
    Map::from_array([
      ("edit", @posoco.OutcomeOk(@posoco.tk_ok_result("edited"))),
    ]),
  )
  let (host, _) = tk_host(
    [
      @posoco.Respond(
        @posoco.tk_tool_call_response(
          "edit",
          "c1",
          Json::object({ "path": Json::string("a.txt") }),
        ),
      ),
      @posoco.Respond(@posoco.tk_stop_response("done one")),
      @posoco.Respond(
        @posoco.tk_tool_call_response(
          "edit",
          "c2",
          Json::object({ "path": Json::string("b.txt") }),
        ),
      ),
      @posoco.Respond(@posoco.tk_stop_response("done two")),
    ],
    tools~,
  )
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let first = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt("edit a"),
    meta: Omitted,
  })
  assert_true(first.stop_reason is EndTurn)
  assert_eq(client.asked.length(), 1)
  assert_eq(tools.exec_records.length(), 1)
  let switched = host.handle_set_config_option(fake_acp_context(client), {
    session_id,
    config_id: "permission",
    value: @acp.SessionConfigValue::ValueId("yolo"),
    meta: Omitted,
  })
  match tk_find_option(switched.config_options, "permission") {
    Some(select) => assert_eq(select.current_value, "yolo")
    None => fail("permission arm missing")
  }
  assert_true(host.sessions[session_id].permission.mode is Yolo)
  let second = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt("edit b"),
    meta: Omitted,
  })
  assert_true(second.stop_reason is EndTurn)
  assert_eq(client.asked.length(), 1)
  assert_eq(tools.exec_records.length(), 2)
}

///|
async test "set_config_option permission readonly rejects write-class calls without asking" {
  let tools = @posoco.RecordingToolProvider(
    [@posoco.tk_tool_def("edit", "edit a file")],
    Map::from_array([
      ("edit", @posoco.OutcomeOk(@posoco.tk_ok_result("edited"))),
    ]),
  )
  let (host, _) = tk_host(
    [
      @posoco.Respond(
        @posoco.tk_tool_call_response(
          "edit",
          "c1",
          Json::object({ "path": Json::string("a.txt") }),
        ),
      ),
      @posoco.Respond(@posoco.tk_stop_response("cannot edit")),
    ],
    tools~,
  )
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let result = host.handle_set_config_option(fake_acp_context(client), {
    session_id,
    config_id: "permission",
    value: @acp.SessionConfigValue::ValueId("readonly"),
    meta: Omitted,
  })
  match tk_find_option(result.config_options, "permission") {
    Some(select) => assert_eq(select.current_value, "readonly")
    None => fail("permission arm missing")
  }
  // The policy rejects the call itself (steering: the model sees NotExecuted), not the client.
  let outcome = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt("edit a"),
    meta: Omitted,
  })
  assert_true(outcome.stop_reason is EndTurn)
  assert_eq(client.asked.length(), 0)
  assert_eq(tools.exec_records.length(), 0)
}

///|
async test "set_config_option permission switches only the calling session and never persists" {
  let fs = FakeFs()
  fs.files["/cetas-home/.cetas/settings.json"] = "{}"
  let (host, _) = tk_host([], fs~)
  let client_a = FakeAcpClient::FakeAcpClient()
  let client_b = FakeAcpClient::FakeAcpClient()
  let a = tk_open_session(host, client_a)
  let b = tk_open_session(host, client_b)
  let result = host.handle_set_config_option(fake_acp_context(client_a), {
    session_id: a,
    config_id: "permission",
    value: @acp.SessionConfigValue::ValueId("yolo"),
    meta: Omitted,
  })
  assert_true(host.sessions[a].permission.mode is Yolo)
  assert_true(host.sessions[b].permission.mode is WorkspaceWrite)
  match tk_find_option(result.config_options, "permission") {
    Some(select) => assert_eq(select.current_value, "yolo")
    None => fail("permission arm missing")
  }
  let b_options = build_config_options(
    host.sessions[b].router,
    host.sessions[b].permission.mode,
  )
  match tk_find_option(b_options, "permission") {
    Some(select) => assert_eq(select.current_value, "workspace_write")
    None => fail("permission arm missing")
  }
  assert_eq(fs.files["/cetas-home/.cetas/settings.json"], "{}")
}

///|
async test "set_config_option permission rejects invalid values" {
  let fs = FakeFs()
  fs.files["/cetas-home/.cetas/settings.json"] = "{}"
  let (host, _) = tk_host([], fs~)
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let rejected : Result[@acp.SetSessionConfigOptionResult, @acp.HandlerError] = Ok(
    host.handle_set_config_option(fake_acp_context(client), {
      session_id,
      config_id: "permission",
      value: @acp.SessionConfigValue::ValueId("sometimes"),
      meta: Omitted,
    }),
  ) catch {
    error => Err(error)
  }
  match rejected {
    Err(Application(message~)) =>
      assert_true(message.contains("unknown permission mode"))
    _ => fail("expected an application error")
  }
  assert_true(host.sessions[session_id].permission.mode is WorkspaceWrite)
  assert_eq(fs.files["/cetas-home/.cetas/settings.json"], "{}")
  let boolean : Result[@acp.SetSessionConfigOptionResult, @acp.HandlerError] = Ok(
    host.handle_set_config_option(fake_acp_context(client), {
      session_id,
      config_id: "permission",
      value: @acp.SessionConfigValue::Boolean(true),
      meta: Omitted,
    }),
  ) catch {
    error => Err(error)
  }
  match boolean {
    Err(Application(message~)) => assert_true(message.contains("value id"))
    _ => fail("expected an application error")
  }
}

// --------------------------------------------------------- lazy model refresh

///|
async test "the model cache seeds the native assembly's router slots" {
  let fs = FakeFs()
  fs.files["/cetas-home/.cetas/settings.json"] = "{\"providers\":{\"opencode\":{\"api_key\":\"sk-zen-test\"}}}"
  fs.files["/cetas-home/.cetas/model_lists.json"] = "{\"opencode\":[{\"model_id\":\"claude-sonnet-5\",\"thinking_efforts\":[],\"default_effort\":null,\"context_window\":null},{\"model_id\":\"gpt-5.1-codex\",\"thinking_efforts\":[],\"default_effort\":null,\"context_window\":null}]}"
  let platform = build_platform(
    home="/cetas-home",
    cwd="/",
    fs,
    mcp_group=None,
    mcp_mode=@mcp.LoadMode::Lazy,
  ) catch {
    error => fail("platform assembly must succeed: " + error.to_string())
  }
  let handle = build_session_agent(platform~, cwd="/") catch {
    error => fail("session assembly must succeed: " + error.to_string())
  }
  assert_eq(handle.router.list_slot_ids(), [
    "opencode/claude-sonnet-5", "opencode/gpt-5.1-codex",
  ])
  assert_true(handle.permission.mode is WorkspaceWrite)
}

///|
async test "an unreadable model cache degrades to the static single slot" {
  let fs = FakeFs()
  fs.files["/cetas-home/.cetas/settings.json"] = "{\"providers\":{\"opencode\":{\"api_key\":\"sk-zen-test\"}}}"
  fs.files["/cetas-home/.cetas/model_lists.json"] = "{corrupt"
  let platform = build_platform(
    home="/cetas-home",
    cwd="/",
    fs,
    mcp_group=None,
    mcp_mode=@mcp.LoadMode::Lazy,
  ) catch {
    error => fail("platform assembly must succeed: " + error.to_string())
  }
  let handle = build_session_agent(platform~, cwd="/") catch {
    _ => fail("a corrupt cache must never fail composition")
  }
  assert_eq(handle.router.list_slot_ids(), ["opencode/claude-sonnet-5"])
}

///|
async test "a session assembles over the platform task group and retires inside it" {
  let fs = FakeFs()
  fs.files["/cetas-home/.cetas/settings.json"] = "{\"providers\":{\"opencode\":{\"api_key\":\"sk-zen-test\"}}}"
  @async.with_task_group(group => {
    let platform = build_platform(
      home="/cetas-home",
      cwd="/",
      fs,
      mcp_group=Some(group),
      mcp_mode=@mcp.LoadMode::Lazy,
    ) catch {
      error => fail("platform assembly must succeed: " + error.to_string())
    }
    let handle = build_session_agent(platform~, cwd="/") catch {
      error => fail("session assembly must succeed: " + error.to_string())
    }
    assert_eq(handle.cwd, "/")
    // Retire before scope close: the nmem flusher stops via on_shutdown, not group cancel.
    handle.agent.shutdown() catch {
      error => fail("session shutdown must succeed: " + error.to_string())
    }
  })
}

///|
async test "the production session assembly always carries nowledge mem" {
  let fs = FakeFs()
  fs.files["/cetas-home/.cetas/settings.json"] = "{\"providers\":{\"opencode\":{\"api_key\":\"sk-zen-test\"}}}"
  let platform = build_platform(
    home="/cetas-home",
    cwd="/",
    fs,
    mcp_group=None,
    mcp_mode=@mcp.LoadMode::Lazy,
  ) catch {
    error => fail("platform assembly must succeed: " + error.to_string())
  }
  let handle = build_session_agent(platform~, cwd="/") catch {
    error => fail("session assembly must succeed: " + error.to_string())
  }
  // nmem's tools fold behind the lazytools gateway, so the command surface
  // is the cheap observable: nmem is the only default extension registering
  // the `memory` / `nmem` commands.
  let mut memory = false
  let mut nmem = false
  for port in handle.agent.commands() {
    for def in port.commands() {
      if def.id == "memory" {
        memory = true
      }
      if def.id == "nmem" {
        nmem = true
      }
    }
  }
  assert_true(memory)
  assert_true(nmem)
}

///|
async test "refresh_model_lists swaps router slots, persists the cache, and pushes updates" {
  let fs = FakeFs()
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
  let router = host.sessions[session.session_id].router
  assert_eq(router.list_slot_ids(), ["test/alpha", "test/beta"])
  host.refresh_model_lists()
  assert_eq(router.list_slot_ids(), ["test/alpha", "test/gamma", "test/delta"])
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
  assert_true(session.session_id.has_prefix("cetas-"))
}

///|
async test "a failing refresh keeps the current slots and pushes nothing" {
  let fs = FakeFs()
  let factory : &@llm.RefreshableProviderFactory = FailingRefreshFactory::{
    fixed_id: "test",
  }
  let (host, _) = tk_host([], fs~, refreshables=[factory])
  let client = FakeAcpClient::FakeAcpClient()
  let session = host.handle_new_session(
    fake_acp_context(client),
    tk_new_session_params(),
  )
  host.refresh_model_lists()
  assert_eq(host.sessions[session.session_id].router.list_slot_ids(), [
    "test/alpha", "test/beta",
  ])
  assert_false(fs.files.contains("/cetas-home/.cetas/model_lists.json"))
  assert_eq(client.sent.length(), 0)
}

// --------------------------------------------------------- session isolation

///|
async test "two sessions prompt independently without cross-session wiring" {
  let (host, _) = tk_host([
    @posoco.Respond(@posoco.tk_stop_response("from one")),
    @posoco.Respond(@posoco.tk_stop_response("from two")),
    @posoco.Respond(@posoco.tk_stop_response("one again")),
  ])
  let client_a = FakeAcpClient::FakeAcpClient()
  let client_b = FakeAcpClient::FakeAcpClient()
  let a = tk_open_session(host, client_a)
  let b = tk_open_session(host, client_b)
  assert_false(a == b)
  // One shared bridge would abort on the second attach; per-session bridges keep both alive.
  let first = host.handle_prompt(fake_acp_context(client_a), {
    session_id: a,
    prompt: tk_prompt("hello a"),
    meta: Omitted,
  })
  assert_true(first.stop_reason is EndTurn)
  let second = host.handle_prompt(fake_acp_context(client_b), {
    session_id: b,
    prompt: tk_prompt("hello b"),
    meta: Omitted,
  })
  assert_true(second.stop_reason is EndTurn)
  let third = host.handle_prompt(fake_acp_context(client_a), {
    session_id: a,
    prompt: tk_prompt("again a"),
    meta: Omitted,
  })
  assert_true(third.stop_reason is EndTurn)
  for frame in client_a.sent {
    assert_eq(frame.session_id, a)
  }
  for frame in client_b.sent {
    assert_eq(frame.session_id, b)
  }
}

///|
async test "set_config_option retunes only the calling session" {
  let fs = FakeFs()
  fs.files["/cetas-home/.cetas/settings.json"] = "{}"
  let (host, _) = tk_host([], fs~)
  let client_a = FakeAcpClient::FakeAcpClient()
  let client_b = FakeAcpClient::FakeAcpClient()
  let a = tk_open_session(host, client_a)
  let b = tk_open_session(host, client_b)
  let result = host.handle_set_config_option(fake_acp_context(client_a), {
    session_id: a,
    config_id: "model",
    value: @acp.SessionConfigValue::ValueId("test/beta"),
    meta: Omitted,
  })
  assert_eq(host.sessions[a].router.active_slot_id(), "test/beta")
  assert_eq(host.sessions[b].router.active_slot_id(), "test/alpha")
  match tk_find_option(result.config_options, "model") {
    Some(select) => assert_eq(select.current_value, "test/beta")
    None => fail("model arm missing")
  }
  let b_options = build_config_options(
    host.sessions[b].router,
    host.sessions[b].permission.mode,
  )
  match tk_find_option(b_options, "model") {
    Some(select) => assert_eq(select.current_value, "test/alpha")
    None => fail("model arm missing")
  }
  assert_true(tk_find_option(b_options, "effort") is Some(_))
  let saved = @json.parse(fs.files["/cetas-home/.cetas/settings.json"]) catch {
    _ => fail("saved settings must parse")
  }
  assert_true(
    saved is Json::Object(fields) &&
    fields.get("model") is Some(Json::String("test/beta")),
  )
  assert_eq(client_b.sent.length(), 0)
}

///|
async test "cancel one session leaves the other's turn running" {
  let (host, _) = tk_host([])
  let client_a = FakeAcpClient::FakeAcpClient()
  let client_b = FakeAcpClient::FakeAcpClient()
  let a = tk_open_session(host, client_a)
  let b = tk_open_session(host, client_b)
  @async.with_task_group(group => {
    let placeholder = async fn(id : String) -> @posoco.TurnResult {
      @async.sleep(10_000)
      {
        message: @posoco.tk_user_msg(""),
        tool_results: [],
        final_session_id: id,
      }
    }
    let task_a = group.spawn(() => placeholder(a))
    let task_b = group.spawn(() => placeholder(b))
    host.sessions[a].in_flight = Some(task_a)
    host.sessions[b].in_flight = Some(task_b)
    host.handle_cancel(fake_acp_context(client_a), {
      session_id: a,
      meta: Omitted,
    })
    let cancelled_a : Bool = try {
      let _ = task_a.wait()
      false
    } catch {
      error => @async.is_cancellation_error(error)
    }
    assert_true(cancelled_a)
    host.handle_cancel(fake_acp_context(client_b), {
      session_id: b,
      meta: Omitted,
    })
    let cancelled_b : Bool = try {
      let _ = task_b.wait()
      false
    } catch {
      error => @async.is_cancellation_error(error)
    }
    assert_true(cancelled_b)
  })
}

// ------------------------------------------- W16: concurrent prompt queuing

///|
/// Chat `i` parks while `gates[i]` is false; the entry/exit log is the serialization
/// witness. Slot index taken at entry, so a cancelled chat never redirects the next.
priv struct GatedModel {
  responses : Array[String]
  gates : Array[Bool]
  log : Array[String]
  mut next : Int
}

///|
impl @posoco.ModelPort for GatedModel with fn chat(
  self,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let i = self.next
  self.next = i + 1
  self.log.push("enter \{i}")
  while !self.gates[i] {
    @async.sleep(1) catch {
      error =>
        raise @posoco.ModelError::Transport(
          "gated model interrupted: " + error.to_string(),
        )
    }
  }
  self.log.push("exit \{i}")
  @posoco.tk_stop_response(self.responses[i])
}

///|
impl @posoco.ModelPort for GatedModel with fn compact(
  _self,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "GatedModel does not implement compact",
  )
}

///|
impl @posoco.ModelPort for GatedModel with fn provider_config(_self) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
async fn tk_wait_log(model : GatedModel, count : Int) -> Unit {
  let mut spins = 0
  while model.log.length() < count && spins < 5000 {
    @async.pause()
    spins += 1
  }
  assert_true(model.log.length() >= count)
}

///|
fn tk_agent_chunk_texts(client : FakeAcpClient) -> Array[String] {
  let texts : Array[String] = []
  for frame in client.sent {
    match frame.update {
      AgentMessageChunk(chunk) =>
        match chunk.content {
          Text({ text, .. }) => texts.push(text)
          _ => ()
        }
      _ => ()
    }
  }
  texts
}

///|
async test "a queued second prompt runs only after the first turn fully settles" {
  let model = GatedModel::{
    responses: ["one", "two"],
    gates: [false, true],
    log: [],
    next: 0,
  }
  let model_port : &@posoco.ModelPort = model
  let host = tk_host_model(model_port)
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  @async.with_task_group(group => {
    let first = group.spawn(() => {
      host.handle_prompt(fake_acp_context(client), {
        session_id,
        prompt: tk_prompt("first"),
        meta: Omitted,
      })
    })
    tk_wait_log(model, 1)
    let second = group.spawn(() => {
      host.handle_prompt(fake_acp_context(client), {
        session_id,
        prompt: tk_prompt("second"),
        meta: Omitted,
      })
    })
    // Scheduling slack for the second handler to barge in if it could.
    @async.pause()
    @async.pause()
    assert_eq(model.log, ["enter 0"])
    model.gates[0] = true
    let r1 = first.wait()
    assert_true(r1.stop_reason is EndTurn)
    let r2 = second.wait()
    assert_true(r2.stop_reason is EndTurn)
    assert_eq(model.log, ["enter 0", "exit 0", "enter 1", "exit 1"])
    assert_eq(tk_agent_chunk_texts(client), ["one", "two"])
  })
}

///|
async test "cancel hits the active turn and a queued prompt still runs" {
  let model = GatedModel::{
    responses: ["one", "two"],
    gates: [false, true],
    log: [],
    next: 0,
  }
  let model_port : &@posoco.ModelPort = model
  let host = tk_host_model(model_port)
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  @async.with_task_group(group => {
    let first = group.spawn(
      () => {
        host.handle_prompt(fake_acp_context(client), {
          session_id,
          prompt: tk_prompt("first"),
          meta: Omitted,
        })
      },
      allow_failure=true,
    )
    tk_wait_log(model, 1)
    let second = group.spawn(() => {
      host.handle_prompt(fake_acp_context(client), {
        session_id,
        prompt: tk_prompt("second"),
        meta: Omitted,
      })
    })
    @async.pause()
    // Cancel must not wake the queued prompt's lock wait (it does not drain the queue).
    host.handle_cancel(fake_acp_context(FakeAcpClient::FakeAcpClient()), {
      session_id,
      meta: Omitted,
    })
    model.gates[0] = true
    let settled_first : Result[@acp.PromptResult, Error] = Ok(first.wait()) catch {
      error => Err(error)
    }
    match settled_first {
      Ok(result) => assert_true(result.stop_reason is Cancelled)
      Err(_) => ()
    }
    let r2 = second.wait()
    assert_true(r2.stop_reason is EndTurn)
    assert_eq(model.log, ["enter 0", "enter 1", "exit 1"])
    assert_eq(tk_agent_chunk_texts(client), ["two"])
  })
}

///|
async test "different sessions still run their turns in parallel" {
  let model = GatedModel::{
    responses: ["a", "b"],
    gates: [false, false],
    log: [],
    next: 0,
  }
  let model_port : &@posoco.ModelPort = model
  let host = tk_host_model(model_port)
  let client_a = FakeAcpClient::FakeAcpClient()
  let client_b = FakeAcpClient::FakeAcpClient()
  let a = tk_open_session(host, client_a)
  let b = tk_open_session(host, client_b)
  @async.with_task_group(group => {
    let task_a = group.spawn(
      () => {
        host.handle_prompt(fake_acp_context(client_a), {
          session_id: a,
          prompt: tk_prompt("to a"),
          meta: Omitted,
        })
      },
      allow_failure=true,
    )
    let task_b = group.spawn(
      () => {
        host.handle_prompt(fake_acp_context(client_b), {
          session_id: b,
          prompt: tk_prompt("to b"),
          meta: Omitted,
        })
      },
      allow_failure=true,
    )
    // Both entries with zero exits is the simultaneity proof.
    tk_wait_log(model, 2)
    assert_true(model.log[0].has_prefix("enter"))
    assert_true(model.log[1].has_prefix("enter"))
    model.gates[0] = true
    model.gates[1] = true
    assert_true(task_a.wait().stop_reason is EndTurn)
    assert_true(task_b.wait().stop_reason is EndTurn)
    assert_eq(tk_agent_chunk_texts(client_a), ["a"])
    assert_eq(tk_agent_chunk_texts(client_b), ["b"])
    for frame in client_a.sent {
      assert_eq(frame.session_id, a)
    }
    for frame in client_b.sent {
      assert_eq(frame.session_id, b)
    }
  })
}

///|
async test "close while a turn runs fails the queued prompt instead of orphaning a turn" {
  let model = GatedModel::{
    responses: ["one", "two"],
    gates: [false, false],
    log: [],
    next: 0,
  }
  let model_port : &@posoco.ModelPort = model
  let host = tk_host_model(model_port)
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  @async.with_task_group(group => {
    let first = group.spawn(
      () => {
        host.handle_prompt(fake_acp_context(client), {
          session_id,
          prompt: tk_prompt("first"),
          meta: Omitted,
        })
      },
      allow_failure=true,
    )
    tk_wait_log(model, 1)
    let second = group.spawn(
      () => {
        // Narrow the error so the wait result carries the typed HandlerError.
        let outcome : Result[@acp.PromptResult, @acp.HandlerError] = Ok(
          host.handle_prompt(fake_acp_context(client), {
            session_id,
            prompt: tk_prompt("second"),
            meta: Omitted,
          }),
        ) catch {
          error => Err(error)
        }
        outcome
      },
      allow_failure=true,
    )
    @async.pause()
    ignore(
      host.handle_close(fake_acp_context(FakeAcpClient::FakeAcpClient()), {
        session_id,
        meta: Omitted,
      }),
    )
    model.gates[0] = true
    let settled_first : Result[@acp.PromptResult, Error] = Ok(first.wait()) catch {
      error => Err(error)
    }
    match settled_first {
      Ok(result) => assert_true(result.stop_reason is Cancelled)
      Err(_) => ()
    }
    match second.wait() {
      Ok(_) => fail("the queued prompt must fail after close")
      Err(InvalidParams(message~)) =>
        assert_true(message.contains("closed while the prompt was queued"))
      Err(_) => fail("expected an invalid-params error for the queued prompt")
    }
    assert_eq(model.log, ["enter 0"])
    assert_false(host.sessions.contains(session_id))
  })
}

// ------------------------------------------------------ session/new params

///|
/// Production-shaped platform (Lazy, no MCP group): injected stdio fails activation without spawning.
async fn tk_mcp_platform() -> Platform raise @posoco.CompositionError {
  let fs = FakeFs()
  fs.files["/cetas-home/.cetas/settings.json"] = "{\"providers\":{\"opencode\":{\"api_key\":\"sk-zen-test\"}}}"
  build_platform(
    home="/cetas-home",
    cwd="/",
    fs,
    mcp_group=None,
    mcp_mode=@mcp.LoadMode::Lazy,
  )
}

///|
/// Real temp project dir with a seeded `.mcp.json` (`entries` = raw JSON
/// body of the `mcpServers` object): discovery reads the native fs, not the
/// FakeFs seam, so union tests need a genuine file. Returns the discover cwd.
async fn tk_mcp_project_dir(label~ : String, entries~ : String) -> String {
  let dir = @fs.tmpdir(prefix="cetas-acp-w1-" + label + "-")
  @fs.write_file(
    dir + "/.mcp.json",
    "{\"mcpServers\":{\{entries}}}",
    create_mode=@fs.CreateMode::CreateOrTruncate,
    permission=0o644,
  )
  dir
}

///|
async fn tk_drop_mcp_project_dir(cwd : String) -> Unit {
  @fs.remove(cwd + "/.mcp.json") catch {
    _ => ()
  }
  @fs.rmdir(cwd) catch {
    _ => ()
  }
}

///|
fn tk_pending_names(bridge : @mcp.MCPToolBridge) -> Array[String] {
  bridge.pending.map(config => config.name)
}

///|
test "acp_mcp_to_config maps stdio servers onto the stdio transport" {
  let server : @acp.McpServer = Stdio({
    name: "fs",
    command: "/usr/local/bin/npx",
    args: ["-y", "some-server"],
    env: [tk_env("API_KEY", "sk"), tk_env("MODE", "fast")],
    meta: Omitted,
  })
  guard acp_mcp_to_config(server) is Ok(config) else {
    fail("stdio server must map")
  }
  assert_eq(config.name, "fs")
  assert_true(config.auth is @mcp.ServerAuth::NoAuth)
  assert_eq(config.timeout_ms, 30_000)
  assert_eq(config.max_reconnects, 1)
  guard config.transport is @transport.AnyTransport::StdioClient(t) else {
    fail("stdio server must map onto the stdio transport")
  }
  assert_eq(t.cmd, "/usr/local/bin/npx")
  assert_eq(t.args, ["-y", "some-server"])
  assert_eq(t.extra_env, Map::from_array([("API_KEY", "sk"), ("MODE", "fast")]))
  assert_true(acp_invalid_headers(server).is_empty())
}

///|
test "acp_mcp_to_config maps http auth and forwards extra headers" {
  let http = fn(
    name : String,
    headers : Array[@acp.McpHttpHeader],
  ) -> @acp.McpServer {
    Http({ name, url: "https://mcp.example.com/mcp", headers, meta: Omitted, })
  }
  guard acp_mcp_to_config(
      http("bearer", [tk_header("Authorization", "Bearer tok-123")]),
    )
    is Ok(bearer) else {
    fail("http server must map")
  }
  assert_eq(bearer.name, "bearer")
  assert_true(bearer.auth is @mcp.ServerAuth::NoAuth)
  guard bearer.transport is @transport.AnyTransport::HttpClient(t) else {
    fail("http server must map onto the http transport")
  }
  assert_eq(t.base_url, "https://mcp.example.com/mcp")
  assert_eq(t.auth_token, Some("tok-123"))
  assert_eq(t.extra_headers, [])
  guard acp_mcp_to_config(
      http("raw", [tk_header("Authorization", "raw-token")]),
    )
    is Ok(raw) else {
    fail("http server must map")
  }
  guard raw.transport is @transport.AnyTransport::HttpClient(raw_t) else {
    fail("http server must map onto the http transport")
  }
  assert_eq(raw_t.auth_token, Some("raw-token"))
  guard acp_mcp_to_config(http("bare", [tk_header("X-Custom", "c")]))
    is Ok(bare) else {
    fail("http server must map")
  }
  guard bare.transport is @transport.AnyTransport::HttpClient(bare_t) else {
    fail("http server must map onto the http transport")
  }
  assert_true(bare_t.auth_token is None)
  assert_eq(bare_t.extra_headers, [("X-Custom", "c")])
  // Repeated Authorization: FIRST becomes the token; upstream last-write-wins puts the LAST on the wire.
  guard acp_mcp_to_config(
      http("dual", [
        tk_header("Authorization", "Bearer one"),
        tk_header("X-Custom", "c"),
        tk_header("Authorization", "Bearer two"),
      ]),
    )
    is Ok(dual) else {
    fail("http server must map")
  }
  guard dual.transport is @transport.AnyTransport::HttpClient(dual_t) else {
    fail("http server must map onto the http transport")
  }
  assert_eq(dual_t.auth_token, Some("one"))
  assert_eq(dual_t.extra_headers, [
    ("X-Custom", "c"),
    ("Authorization", "Bearer two"),
  ])
}

///|
test "acp_mcp_to_config skips empty-name http headers and reports their indexes" {
  let blank_server : @acp.McpServer = Http({
    name: "blank",
    url: "https://mcp.example.com/mcp",
    headers: [
      tk_header("", "v"),
      tk_header("X-Custom", "c"),
      tk_header("", "w"),
    ],
    meta: Omitted,
  })
  guard acp_mcp_to_config(blank_server) is Ok(blank) else {
    fail("http server must map")
  }
  guard blank.transport is @transport.AnyTransport::HttpClient(blank_t) else {
    fail("http server must map onto the http transport")
  }
  assert_true(blank_t.auth_token is None)
  assert_eq(blank_t.extra_headers, [("X-Custom", "c")])
  assert_eq(acp_invalid_headers(blank_server), [0, 2])
}

///|
test "acp_mcp_to_config rejects sse servers" {
  let mapped = acp_mcp_to_config(
    Sse({
      name: "legacy",
      url: "https://old.example.com/sse",
      headers: [],
      meta: Omitted,
    }),
  )
  guard mapped is Err(message) else { fail("sse must be refused") }
  assert_true(message.contains("sse"))
  assert_true(message.contains("legacy"))
}

///|
async test "params MCP servers degrade per-server without failing the session" {
  let platform = tk_mcp_platform() catch {
    error => fail("platform assembly must succeed: " + error.to_string())
  }
  let injected : Array[@acp.McpServer] = [
    Stdio({
      name: "ghost",
      command: "/nonexistent-cetas-mcp-binary",
      args: [],
      env: [],
      meta: Omitted,
    }),
    Sse({
      name: "old-sse",
      url: "https://old.example.com/sse",
      headers: [],
      meta: Omitted,
    }),
  ]
  let session = build_session_agent(
    platform~,
    cwd="/w2-a",
    mcp_servers=injected,
  ) catch {
    error =>
      fail("per-server failures must never fail assembly: " + error.to_string())
  }
  assert_eq(session.cwd, "/w2-a")
  let fallback = build_session_agent(platform~, cwd="/w2-b") catch {
    error => fail("discover fallback must compose: " + error.to_string())
  }
  assert_eq(fallback.cwd, "/w2-b")
}

///|
async test "http servers with an unmappable header never fail the session" {
  let platform = tk_mcp_platform() catch {
    error => fail("platform assembly must succeed: " + error.to_string())
  }
  let injected : Array[@acp.McpServer] = [
    Http({
      name: "remote",
      url: "http://127.0.0.1:1/mcp",
      headers: [
        tk_header("Authorization", "Bearer tok-123"),
        tk_header("X-Custom", "anything"),
        tk_header("", "blank"),
      ],
      meta: Omitted,
    }),
  ]
  let session = build_session_agent(
    platform~,
    cwd="/w2-c",
    mcp_servers=injected,
  ) catch {
    error =>
      fail(
        "invalid-header warning must not fail assembly: " + error.to_string(),
      )
  }
  assert_eq(session.cwd, "/w2-c")
}

///|
async test "union keeps an injected server and a distinct local server" {
  let cwd = tk_mcp_project_dir(
    label="union-both",
    entries="\"local-fs\":{\"command\":\"/nonexistent-cetas-mcp-binary\"}",
  )
  guard @mcp.MCPToolBridge::discover(cwd~, home=cwd + "/nohome") is Ok(bridge) else {
    fail("discover must read the seeded mcp.json")
  }
  assert_eq(tk_pending_names(bridge), ["local-fs"])
  let injected : Array[@acp.McpServer] = [
    Http({
      name: "remote",
      url: "http://127.0.0.1:1/mcp",
      headers: [],
      meta: Omitted,
    }),
  ]
  union_mcp_servers(bridge, injected)
  // Both sources stay on the connection roster: local discover order first,
  // then the injected declarations.
  assert_eq(tk_pending_names(bridge), ["local-fs", "remote"])
  assert_true(bridge.configs.contains("local-fs"))
  assert_true(bridge.configs.contains("remote"))
  // The composed session carries the union too: the local stdio server fails
  // activation (no task group in tests) without failing the session.
  let platform = tk_mcp_platform() catch {
    error => fail("platform assembly must succeed: " + error.to_string())
  }
  let session = build_session_agent(platform~, cwd~, mcp_servers=injected) catch {
    error => fail("union assembly must compose: " + error.to_string())
  }
  assert_eq(session.cwd, cwd)
  tk_drop_mcp_project_dir(cwd)
}

///|
async test "an injected URL shadows the local server on the same endpoint" {
  let cwd = tk_mcp_project_dir(
    label="union-url",
    entries="\"local-remote\":{\"url\":\"http://127.0.0.1:1/mcp\"}",
  )
  guard @mcp.MCPToolBridge::discover(cwd~, home=cwd + "/nohome") is Ok(bridge) else {
    fail("discover must read the seeded mcp.json")
  }
  let injected : Array[@acp.McpServer] = [
    Http({
      name: "remote",
      url: "http://127.0.0.1:1/mcp",
      headers: [],
      meta: Omitted,
    }),
  ]
  union_mcp_servers(bridge, injected)
  // Same endpoint, different names: injection wins, the local entry is gone
  // from pending AND configs (a reconnect cannot resurrect it).
  assert_eq(tk_pending_names(bridge), ["remote"])
  assert_false(bridge.configs.contains("local-remote"))
  assert_true(bridge.configs.contains("remote"))
  tk_drop_mcp_project_dir(cwd)
}

///|
async test "an injected name shadows a local server with a different endpoint" {
  let cwd = tk_mcp_project_dir(
    label="union-name",
    entries="\"remote\":{\"command\":\"/nonexistent-cetas-mcp-binary\"}",
  )
  guard @mcp.MCPToolBridge::discover(cwd~, home=cwd + "/nohome") is Ok(bridge) else {
    fail("discover must read the seeded mcp.json")
  }
  let injected : Array[@acp.McpServer] = [
    Http({
      name: "remote",
      url: "http://127.0.0.1:1/mcp",
      headers: [],
      meta: Omitted,
    }),
  ]
  union_mcp_servers(bridge, injected)
  // Same name, different transport: the local stdio entry is skipped and the
  // injected http config is the one registered under 'remote'.
  assert_eq(tk_pending_names(bridge), ["remote"])
  assert_true(bridge.configs.contains("remote"))
  guard bridge.configs["remote"].transport
    is @transport.AnyTransport::HttpClient(t) else {
    fail("the surviving 'remote' must be the injected http config")
  }
  assert_eq(t.base_url, "http://127.0.0.1:1/mcp")
  tk_drop_mcp_project_dir(cwd)
}

///|
async test "an empty injection leaves the discovered locals untouched" {
  let cwd = tk_mcp_project_dir(
    label="union-local",
    entries=(
      #|"local-fs":{"command":"/nonexistent-cetas-mcp-binary"},
      #|"local-remote":{"url":"http://127.0.0.1:1/mcp"}
    ),
  )
  guard @mcp.MCPToolBridge::discover(cwd~, home=cwd + "/nohome") is Ok(bridge) else {
    fail("discover must read the seeded mcp.json")
  }
  union_mcp_servers(bridge, [])
  // Pure-local session regression: no shadowing, no reordering, both stay
  // registered exactly as discover produced them.
  assert_eq(tk_pending_names(bridge), ["local-fs", "local-remote"])
  assert_true(bridge.configs.contains("local-fs"))
  assert_true(bridge.configs.contains("local-remote"))
  tk_drop_mcp_project_dir(cwd)
}

///|
async test "session cwd comes from params and falls back to the process cwd" {
  let (host, _) = tk_host([], process_cwd="/proc-cwd")
  let a = host.handle_new_session(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    tk_new_session_params(cwd="/w2-a"),
  )
  let b = host.handle_new_session(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    tk_new_session_params(cwd="/w2-b"),
  )
  assert_eq(host.sessions[a.session_id].cwd, "/w2-a")
  assert_eq(host.sessions[b.session_id].cwd, "/w2-b")
  let fallback = host.handle_new_session(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    tk_new_session_params(cwd=""),
  )
  assert_eq(host.sessions[fallback.session_id].cwd, "/proc-cwd")
}

// ------------------------------------------------------ load / resume / list

///|
async test "load replays persisted history as user and agent chunks" {
  let store = @fs_session.JsonlSessionStore(tk_temp_root("load"))
  let fs = FakeFs()
  let (host, _) = tk_host(
    [@posoco.Respond(@posoco.tk_stop_response("w4 answer"))],
    fs~,
    store~,
  )
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let turn = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt("hello w4"),
    meta: Omitted,
  })
  assert_true(turn.stop_reason is EndTurn)
  let reconnected = FakeAcpClient::FakeAcpClient()
  let result = host.handle_load_session(
    fake_acp_context(reconnected),
    tk_load_params(session_id),
  )
  assert_true(result.config_options is Value(_))
  let mut saw_user = false
  let mut saw_agent = false
  for frame in reconnected.sent {
    match frame.update {
      UserMessageChunk(chunk) =>
        match chunk.content {
          Text({ text, .. }) => if text == "hello w4" { saw_user = true }
          _ => ()
        }
      AgentMessageChunk(chunk) =>
        match chunk.content {
          Text({ text, .. }) => if text == "w4 answer" { saw_agent = true }
          _ => ()
        }
      _ => ()
    }
  }
  assert_true(saw_user)
  assert_true(saw_agent)
  assert_true(host.sessions.contains(session_id))
  assert_eq(host.sessions[session_id].cwd, "/")
}

///|
async test "resume rebuilds the session without replaying history" {
  let fs = FakeFs()
  let (host, _) = tk_host(
    [
      @posoco.Respond(@posoco.tk_stop_response("first")),
      @posoco.Respond(@posoco.tk_stop_response("after resume")),
    ],
    fs~,
  )
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let turn = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt("one"),
    meta: Omitted,
  })
  assert_true(turn.stop_reason is EndTurn)
  let reconnected = FakeAcpClient::FakeAcpClient()
  let result = host.handle_resume_session(
    fake_acp_context(reconnected),
    tk_resume_params(session_id),
  )
  assert_eq(reconnected.sent.length(), 0)
  assert_true(result.config_options is Value(_))
  let after = host.handle_prompt(fake_acp_context(reconnected), {
    session_id,
    prompt: tk_prompt("two"),
    meta: Omitted,
  })
  assert_true(after.stop_reason is EndTurn)
}

///|
async test "sidecar round-trips cwd model and effort through load" {
  let fs = FakeFs()
  let (host, _) = tk_host([], fs~)
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = host.handle_new_session(
      fake_acp_context(client),
      tk_new_session_params(cwd="/w4-round"),
    ).session_id
  ignore(
    host.handle_set_config_option_sidecar(fake_acp_context(client), {
      session_id,
      config_id: "effort",
      value: @acp.SessionConfigValue::ValueId("high"),
      meta: Omitted,
    }),
  )
  let sidecar_file = sidecar_path("/cetas-home", session_id)
  guard fs.files.contains(sidecar_file) else {
    fail("session/new must write the sidecar")
  }
  let saved = @json.parse(fs.files[sidecar_file]) catch {
    _ => fail("sidecar must parse")
  }
  guard saved is Json::Object(fields) else { fail("sidecar must be an object") }
  assert_true(fields.get("cwd") is Some(Json::String("/w4-round")))
  assert_true(fields.get("model") is Some(Json::String("test/alpha")))
  assert_true(fields.get("effort") is Some(Json::String("high")))
  assert_true(fields.get("mcp_servers") is Some(Json::Array([])))
  let loaded = host.handle_load_session(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    tk_load_params(session_id, cwd=""),
  )
  guard loaded.config_options is Value(options) else {
    fail("load must advertise config options")
  }
  match tk_find_option(options, "effort") {
    Some(select) => assert_eq(select.current_value, "high")
    None => fail("effort arm missing after restore")
  }
  assert_eq(host.sessions[session_id].cwd, "/w4-round")
  assert_eq(host.sessions[session_id].router.active_slot_id(), "test/alpha")
  assert_eq(host.sessions[session_id].router.active_effort(), Some("high"))
}

///|
async test "list answers persisted sessions and filters by cwd" {
  let store = @fs_session.JsonlSessionStore(tk_temp_root("list"))
  let fs = FakeFs()
  let (host, _) = tk_host(
    [
      @posoco.Respond(@posoco.tk_stop_response("a")),
      @posoco.Respond(@posoco.tk_stop_response("b")),
    ],
    fs~,
    store~,
  )
  let a = host.handle_new_session(
      fake_acp_context(FakeAcpClient::FakeAcpClient()),
      tk_new_session_params(cwd="/w4-list-a"),
    ).session_id
  let b = host.handle_new_session(
      fake_acp_context(FakeAcpClient::FakeAcpClient()),
      tk_new_session_params(cwd="/w4-list-b"),
    ).session_id
  for id in [a, b] {
    let turn = host.handle_prompt(
      fake_acp_context(FakeAcpClient::FakeAcpClient()),
      { session_id: id, prompt: tk_prompt("persist me"), meta: Omitted, },
    )
    assert_true(turn.stop_reason is EndTurn)
  }
  let all = host.handle_list_sessions(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    { cwd: Omitted, cursor: Omitted, meta: Omitted, },
  )
  let mut saw_a = false
  let mut saw_b = false
  for info in all.sessions {
    if info.session_id == a {
      saw_a = true
      assert_eq(info.cwd, "/w4-list-a")
    }
    if info.session_id == b {
      saw_b = true
      assert_eq(info.cwd, "/w4-list-b")
    }
  }
  assert_true(saw_a)
  assert_true(saw_b)
  assert_true(all.next_cursor is Omitted)
  let filtered = host.handle_list_sessions(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    { cwd: Value("/w4-list-a"), cursor: Omitted, meta: Omitted, },
  )
  assert_eq(filtered.sessions.length(), 1)
  assert_eq(filtered.sessions[0].session_id, a)
  assert_eq(filtered.sessions[0].cwd, "/w4-list-a")
}

///|
async test "load and resume reject an unknown session id" {
  let (host, _) = tk_host([])
  let load : Result[@acp.LoadSessionResult, @acp.HandlerError] = Ok(
    host.handle_load_session(
      fake_acp_context(FakeAcpClient::FakeAcpClient()),
      tk_load_params("cetas-404"),
    ),
  ) catch {
    error => Err(error)
  }
  match load {
    Err(InvalidParams(message~)) =>
      assert_true(message.contains("unknown session"))
    _ => fail("expected an invalid-params error")
  }
  let resume_outcome : Result[@acp.ResumeSessionResult, @acp.HandlerError] = Ok(
    host.handle_resume_session(
      fake_acp_context(FakeAcpClient::FakeAcpClient()),
      tk_resume_params("cetas-404"),
    ),
  ) catch {
    error => Err(error)
  }
  match resume_outcome {
    Err(InvalidParams(message~)) =>
      assert_true(message.contains("unknown session"))
    _ => fail("expected an invalid-params error")
  }
  assert_false(host.sessions.contains("cetas-404"))
}

///|
async test "set_config_option updates the sidecar model field" {
  let fs = FakeFs()
  let (host, _) = tk_host([], fs~)
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  ignore(
    host.handle_set_config_option_sidecar(fake_acp_context(client), {
      session_id,
      config_id: "model",
      value: @acp.SessionConfigValue::ValueId("test/beta"),
      meta: Omitted,
    }),
  )
  let sidecar_file = sidecar_path("/cetas-home", session_id)
  guard fs.files.contains(sidecar_file) else {
    fail("the model switch must write the sidecar")
  }
  let saved = @json.parse(fs.files[sidecar_file]) catch {
    _ => fail("sidecar must parse")
  }
  guard saved is Json::Object(fields) else { fail("sidecar must be an object") }
  assert_true(fields.get("model") is Some(Json::String("test/beta")))
  // beta advertises no efforts, so the effort slot resets to null.
  assert_true(fields.get("effort") is Some(Json::Null))
  assert_true(fields.get("cwd") is Some(Json::String("/")))
  ignore(
    host.handle_load_session(
      fake_acp_context(FakeAcpClient::FakeAcpClient()),
      tk_load_params(session_id, cwd=""),
    ),
  )
  assert_eq(host.sessions[session_id].router.active_slot_id(), "test/beta")
}

// --------------------------------------------------- W7: session/fork

///|
fn tk_fork_params(
  session_id : String,
  cwd? : String = "/",
  mcp_servers? : Array[@acp.McpServer] = [],
) -> @acp.ForkSessionParams {
  {
    cwd,
    session_id,
    additional_directories: Omitted,
    mcp_servers: Value(mcp_servers),
    meta: Omitted,
  }
}

///|
fn tk_session_texts(session : @posoco.Session) -> Array[String] {
  let texts : Array[String] = []
  for message in session.messages {
    match message {
      UserMessage(content~) =>
        for block in content {
          match block {
            Text(text) => texts.push(text)
            _ => ()
          }
        }
      AssistantMessage(content~, ..) =>
        for block in content {
          match block {
            Text(text) => texts.push(text)
            _ => ()
          }
        }
      _ => ()
    }
  }
  texts
}

///|
async fn tk_load_history(
  host : CetasAcpHost,
  session_id : String,
) -> @posoco.Session {
  let loaded : Result[@posoco.Session, Error] = Ok(
    host.session_store.load(session_id),
  ) catch {
    error => Err(error)
  }
  match loaded {
    Ok(session) => session
    Err(error) =>
      fail("history for '" + session_id + "' must load: " + error.to_string())
  }
}

///|
async test "fork branches a live parent into an independent promptable child" {
  let store = @fs_session.JsonlSessionStore(tk_temp_root("fork-live"))
  let fs = FakeFs()
  let (host, _) = tk_host(
    [
      @posoco.Respond(@posoco.tk_stop_response("turn one")),
      @posoco.Respond(@posoco.tk_stop_response("turn two")),
      @posoco.Respond(@posoco.tk_stop_response("turn three")),
    ],
    fs~,
    store~,
  )
  let client = FakeAcpClient::FakeAcpClient()
  let parent = tk_open_session(host, client)
  let turn = host.handle_prompt(fake_acp_context(client), {
    session_id: parent,
    prompt: tk_prompt("hello parent"),
    meta: Omitted,
  })
  assert_true(turn.stop_reason is EndTurn)
  let result = host.handle_fork_session(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    tk_fork_params(parent),
  )
  let child = result.session_id
  assert_true(child != parent)
  assert_true(tk_durable_id_shape(child))
  guard result.modes is Value(child_modes) else {
    fail("fork must advertise the child's modes")
  }
  assert_eq(child_modes.current_mode_id, "default")
  guard result.config_options is Value(options) else {
    fail("fork must advertise the child's config options")
  }
  match tk_find_option(options, "model") {
    Some(select) => assert_eq(select.current_value, "test/alpha")
    None => fail("model arm missing on the forked session")
  }
  let texts = tk_session_texts(tk_load_history(host, child))
  assert_true(texts.contains("hello parent"))
  assert_true(texts.contains("turn one"))
  let child_turn = host.handle_prompt(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    { session_id: child, prompt: tk_prompt("hello child"), meta: Omitted, },
  )
  assert_true(child_turn.stop_reason is EndTurn)
  assert_true(host.sessions.contains(parent))
  let parent_turn = host.handle_prompt(fake_acp_context(client), {
    session_id: parent,
    prompt: tk_prompt("hello again"),
    meta: Omitted,
  })
  assert_true(parent_turn.stop_reason is EndTurn)
}

///|
async test "fork branches a closed parent from its persisted state" {
  let store = @fs_session.JsonlSessionStore(tk_temp_root("fork-closed"))
  let fs = FakeFs()
  let (host, _) = tk_host(
    [
      @posoco.Respond(@posoco.tk_stop_response("closed answer")),
      @posoco.Respond(@posoco.tk_stop_response("child answer")),
    ],
    fs~,
    store~,
  )
  let client = FakeAcpClient::FakeAcpClient()
  let parent = tk_open_session(host, client)
  let turn = host.handle_prompt(fake_acp_context(client), {
    session_id: parent,
    prompt: tk_prompt("persist me"),
    meta: Omitted,
  })
  assert_true(turn.stop_reason is EndTurn)
  ignore(
    host.handle_close(fake_acp_context(client), {
      session_id: parent,
      meta: Omitted,
    }),
  )
  assert_false(host.sessions.contains(parent))
  let result = host.handle_fork_session(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    tk_fork_params(parent),
  )
  let child = result.session_id
  assert_true(child != parent)
  let texts = tk_session_texts(tk_load_history(host, child))
  assert_true(texts.contains("persist me"))
  assert_true(texts.contains("closed answer"))
  let child_turn = host.handle_prompt(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    { session_id: child, prompt: tk_prompt("go on"), meta: Omitted, },
  )
  assert_true(child_turn.stop_reason is EndTurn)
  assert_false(host.sessions.contains(parent))
}

///|
async test "fork cwd override anchors the child at the fork cwd" {
  let fs = FakeFs()
  let (host, _) = tk_host([], fs~)
  let parent = host.handle_new_session(
      fake_acp_context(FakeAcpClient::FakeAcpClient()),
      tk_new_session_params(cwd="/worktree-main"),
    ).session_id
  let child = host.handle_fork_session(
      fake_acp_context(FakeAcpClient::FakeAcpClient()),
      tk_fork_params(parent, cwd="/forked"),
    ).session_id
  assert_eq(host.sessions[child].cwd, "/forked")
  assert_eq(host.sessions[parent].cwd, "/worktree-main")
  let parent_saved = @json.parse(fs.files[sidecar_path("/cetas-home", parent)]) catch {
    _ => fail("parent sidecar must parse")
  }
  guard parent_saved is Json::Object(parent_fields) else {
    fail("parent sidecar must be an object")
  }
  assert_true(parent_fields.get("cwd") is Some(Json::String("/worktree-main")))
  let child_saved = @json.parse(fs.files[sidecar_path("/cetas-home", child)]) catch {
    _ => fail("child sidecar must parse")
  }
  guard child_saved is Json::Object(child_fields) else {
    fail("child sidecar must be an object")
  }
  assert_true(child_fields.get("cwd") is Some(Json::String("/forked")))
}

///|
async test "fork inherits the parent sidecar roster and selection" {
  let fs = FakeFs()
  let (host, _) = tk_host([], fs~)
  let server : @acp.McpServer = Stdio({
    name: "notes",
    command: "/usr/local/bin/npx",
    args: ["-y", "notes"],
    env: [],
    meta: Omitted,
  })
  let client = FakeAcpClient::FakeAcpClient()
  let parent = host.handle_new_session(
      fake_acp_context(client),
      tk_new_session_params(cwd="/w7-inherit", mcp_servers=[server]),
    ).session_id
  ignore(
    host.handle_set_config_option_sidecar(fake_acp_context(client), {
      session_id: parent,
      config_id: "effort",
      value: @acp.SessionConfigValue::ValueId("high"),
      meta: Omitted,
    }),
  )
  let result = host.handle_fork_session(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    {
      cwd: "",
      session_id: parent,
      additional_directories: Omitted,
      mcp_servers: Omitted,
      meta: Omitted,
    },
  )
  let child = result.session_id
  let child_saved = @json.parse(fs.files[sidecar_path("/cetas-home", child)]) catch {
    _ => fail("child sidecar must parse")
  }
  guard child_saved is Json::Object(fields) else {
    fail("child sidecar must be an object")
  }
  assert_true(fields.get("effort") is Some(Json::String("high")))
  assert_true(fields.get("model") is Some(Json::String("test/alpha")))
  assert_true(fields.get("cwd") is Some(Json::String("/w7-inherit")))
  assert_true(
    fields.get("mcp_servers") is Some(Json::Array([Json::String("notes")])),
  )
  assert_eq(host.sessions[child].router.active_effort(), Some("high"))
  assert_eq(host.sessions[child].router.active_slot_id(), "test/alpha")
  guard result.config_options is Value(options) else {
    fail("fork must advertise the child's config options")
  }
  match tk_find_option(options, "effort") {
    Some(select) => assert_eq(select.current_value, "high")
    None => fail("effort arm missing on the forked session")
  }
  assert_eq(host.sessions[parent].router.active_effort(), Some("high"))
  let parent_saved = @json.parse(fs.files[sidecar_path("/cetas-home", parent)]) catch {
    _ => fail("parent sidecar must parse")
  }
  guard parent_saved is Json::Object(parent_fields) else {
    fail("parent sidecar must be an object")
  }
  assert_true(
    parent_fields.get("mcp_servers")
    is Some(Json::Array([Json::String("notes")])),
  )
}

///|
async test "fork rejects an unknown or invalid session id" {
  let (host, _) = tk_host([])
  let unknown : Result[@acp.ForkSessionResult, @acp.HandlerError] = Ok(
    host.handle_fork_session(
      fake_acp_context(FakeAcpClient::FakeAcpClient()),
      tk_fork_params("cetas-404"),
    ),
  ) catch {
    error => Err(error)
  }
  match unknown {
    Err(InvalidParams(message~)) =>
      assert_true(message.contains("unknown session"))
    _ => fail("expected an invalid-params error")
  }
  let malformed : Result[@acp.ForkSessionResult, @acp.HandlerError] = Ok(
    host.handle_fork_session(
      fake_acp_context(FakeAcpClient::FakeAcpClient()),
      tk_fork_params("../escape"),
    ),
  ) catch {
    error => Err(error)
  }
  match malformed {
    Err(InvalidParams(message~)) =>
      assert_true(message.contains("invalid session id"))
    _ => fail("expected an invalid-params error")
  }
  assert_eq(host.sessions.length(), 0)
}

///|
async test "fork leaves the parent sidecar and history byte-identical" {
  let store = @fs_session.JsonlSessionStore(tk_temp_root("fork-frozen"))
  let fs = FakeFs()
  let (host, _) = tk_host(
    [@posoco.Respond(@posoco.tk_stop_response("parent answer"))],
    fs~,
    store~,
  )
  let client = FakeAcpClient::FakeAcpClient()
  let parent = tk_open_session(host, client)
  let turn = host.handle_prompt(fake_acp_context(client), {
    session_id: parent,
    prompt: tk_prompt("frozen"),
    meta: Omitted,
  })
  assert_true(turn.stop_reason is EndTurn)
  let sidecar_before = fs.files[sidecar_path("/cetas-home", parent)]
  let history_before = tk_load_history(host, parent)
  ignore(
    host.handle_fork_session(
      fake_acp_context(FakeAcpClient::FakeAcpClient()),
      tk_fork_params(parent, cwd="/forked"),
    ),
  )
  // History compared via canonical JSONL (the real store file sits outside the fake fs).
  assert_eq(fs.files[sidecar_path("/cetas-home", parent)], sidecar_before)
  let history_after = tk_load_history(host, parent)
  assert_eq(
    @fs_session.session_to_jsonl(history_after),
    @fs_session.session_to_jsonl(history_before),
  )
  assert_true(host.sessions.contains(parent))
}

// --------------------------------------------------- W8: session/delete

///|
fn tk_delete_params(session_id : String) -> @acp.DeleteSessionParams {
  { session_id, meta: Omitted, }
}

///|
/// Delete-test host over real disk: one fresh temp home holds sidecar and JSONL history.
async fn tk_host_native(
  steps : Array[@posoco.ScriptedModelStep],
  home : String,
) -> CetasAcpHost {
  let store = @fs_session.JsonlSessionStore(home + "/.cetas/sessions")
  let fs = @workspace.NativeWorkspaceFs()
  fs.mkdir(home + "/.cetas/sessions", recursive=true) catch {
    _ => ()
  }
  CetasAcpHost::of(
    spawn_session=tk_spawn_session(
      @posoco.ScriptedModel(steps),
      @posoco.RecordingToolProvider([], Map::from_array([])),
      "/",
      store=Some(store as &@posoco.SessionStore),
    ),
    home~,
    fs~,
    session_store=store,
  )
}

///|
async fn tk_file_exists(host : CetasAcpHost, path : String) -> Bool noraise {
  host.fs.exists(path) catch {
    _ => false
  }
}

///|
test "agent_spec advertises delete and the http MCP capability" {
  let (host, _) = tk_host([])
  guard host.agent_spec() is Ok(spec) else { fail("agent_spec must compose") }
  assert_true(spec.sessions.delete_handler is Some(_))
  // ext-mcp has no SSE client; the gate must reject Sse injections before any handler.
  assert_true(spec.support.mcp_http)
  assert_false(spec.support.mcp_sse)
}

///|
async test "delete retires a live session and removes both persisted files" {
  let home = tk_temp_root("delete-live") + "/home"
  let host = tk_host_native(
    [@posoco.Respond(@posoco.tk_stop_response("hi"))],
    home,
  )
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let turn = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt("persist me"),
    meta: Omitted,
  })
  assert_true(turn.stop_reason is EndTurn)
  let sidecar_file = sidecar_path(home, session_id)
  let history_file = @fs_session.jsonl_session_path(
    host.session_store.root_dir,
    session_id,
  )
  assert_true(tk_file_exists(host, sidecar_file))
  assert_true(tk_file_exists(host, history_file))
  let result = host.handle_delete_session(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    tk_delete_params(session_id),
  )
  assert_true(result.meta is Omitted)
  assert_false(tk_file_exists(host, sidecar_file))
  assert_false(tk_file_exists(host, history_file))
  let rejected : Result[@acp.PromptResult, @acp.HandlerError] = Ok(
    host.handle_prompt(fake_acp_context(client), {
      session_id,
      prompt: tk_prompt("again"),
      meta: Omitted,
    }),
  ) catch {
    error => Err(error)
  }
  match rejected {
    Ok(_) => fail("a deleted session must reject prompts")
    Err(InvalidParams(message~)) =>
      assert_true(message.contains("unknown session"))
    Err(_) => fail("expected an invalid-params error")
  }
  let listed = host.handle_list_sessions(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    { cwd: Omitted, cursor: Omitted, meta: Omitted, },
  )
  for info in listed.sessions {
    assert_false(info.session_id == session_id)
  }
}

///|
async test "delete removes a closed session's persisted history and sidecar" {
  let home = tk_temp_root("delete-closed") + "/home"
  let host = tk_host_native(
    [@posoco.Respond(@posoco.tk_stop_response("hi"))],
    home,
  )
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let turn = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt("persist me"),
    meta: Omitted,
  })
  assert_true(turn.stop_reason is EndTurn)
  ignore(
    host.handle_close(fake_acp_context(client), { session_id, meta: Omitted, }),
  )
  assert_false(host.sessions.contains(session_id))
  let history_file = @fs_session.jsonl_session_path(
    host.session_store.root_dir,
    session_id,
  )
  assert_true(tk_file_exists(host, history_file))
  ignore(
    host.handle_delete_session(
      fake_acp_context(FakeAcpClient::FakeAcpClient()),
      tk_delete_params(session_id),
    ),
  )
  assert_false(tk_file_exists(host, history_file))
  assert_false(tk_file_exists(host, sidecar_path(home, session_id)))
  let load : Result[@acp.LoadSessionResult, @acp.HandlerError] = Ok(
    host.handle_load_session(
      fake_acp_context(FakeAcpClient::FakeAcpClient()),
      tk_load_params(session_id),
    ),
  ) catch {
    error => Err(error)
  }
  match load {
    Err(InvalidParams(message~)) =>
      assert_true(message.contains("unknown session"))
    _ => fail("a deleted id must not load")
  }
}

///|
async test "delete rejects unknown and malformed session ids" {
  let (host, _) = tk_host([])
  let unknown : Result[@acp.DeleteSessionResult, @acp.HandlerError] = Ok(
    host.handle_delete_session(
      fake_acp_context(FakeAcpClient::FakeAcpClient()),
      tk_delete_params("cetas-404"),
    ),
  ) catch {
    error => Err(error)
  }
  match unknown {
    // Not close's silent no-op: delete is destructive, mistyped ids must be reported.
    Err(InvalidParams(message~)) =>
      assert_true(message.contains("unknown session"))
    _ => fail("expected an invalid-params error")
  }
  let malformed : Result[@acp.DeleteSessionResult, @acp.HandlerError] = Ok(
    host.handle_delete_session(
      fake_acp_context(FakeAcpClient::FakeAcpClient()),
      tk_delete_params("../escape"),
    ),
  ) catch {
    error => Err(error)
  }
  match malformed {
    Err(InvalidParams(message~)) =>
      assert_true(message.contains("invalid session id"))
    _ => fail("expected an invalid-params error")
  }
}

///|
async test "delete leaves the other session untouched" {
  let (host, _) = tk_host([
    @posoco.Respond(@posoco.tk_stop_response("b answers")),
  ])
  let client_a = FakeAcpClient::FakeAcpClient()
  let client_b = FakeAcpClient::FakeAcpClient()
  let a = tk_open_session(host, client_a)
  let b = tk_open_session(host, client_b)
  ignore(
    host.handle_delete_session(
      fake_acp_context(FakeAcpClient::FakeAcpClient()),
      tk_delete_params(a),
    ),
  )
  assert_false(host.sessions.contains(a))
  assert_false(tk_file_exists(host, sidecar_path("/cetas-home", a)))
  assert_true(tk_file_exists(host, sidecar_path("/cetas-home", b)))
  let b_turn = host.handle_prompt(fake_acp_context(client_b), {
    session_id: b,
    prompt: tk_prompt("hello b"),
    meta: Omitted,
  })
  assert_true(b_turn.stop_reason is EndTurn)
}

///|
async test "delete failure surfaces as an application error naming the file" {
  let fs = FakeFs()
  let (host, _) = tk_host([], fs~)
  let session_id = tk_open_session(host, FakeAcpClient::FakeAcpClient())
  let sidecar_file = sidecar_path("/cetas-home", session_id)
  guard fs.files.contains(sidecar_file) else {
    fail("session/new must write the sidecar")
  }
  fs.fail_removes = true
  let outcome : Result[@acp.DeleteSessionResult, @acp.HandlerError] = Ok(
    host.handle_delete_session(
      fake_acp_context(FakeAcpClient::FakeAcpClient()),
      tk_delete_params(session_id),
    ),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Err(Application(message~)) => {
      assert_true(message.contains("sidecar"))
      assert_true(message.contains(sidecar_file))
    }
    _ => fail("a failed file removal must be reported, never silent")
  }
  assert_false(host.sessions.contains(session_id))
  assert_true(fs.files.contains(sidecar_file))
}

// ---------------------------------------------- W5: persistence write mutex

///|
/// With the persist mutex held elsewhere, set_config_option parks its read-merge-write at the lock.
async test "selection persistence waits on the process persist mutex" {
  let fs = FakeFs()
  let seeded = "{\"providers\":{\"kimi\":{}}}"
  fs.files["/cetas-home/.cetas/settings.json"] = seeded
  let (host, _) = tk_host([], fs~)
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  @async.with_task_group(group => {
    acp_persist_mutex.acquire() catch {
      _ => fail("the test task must acquire the persist mutex")
    }
    let task = group.spawn(
      () => {
        host.handle_set_config_option(fake_acp_context(client), {
          session_id,
          config_id: "model",
          value: @acp.SessionConfigValue::ValueId("test/beta"),
          meta: Omitted,
        })
      },
      allow_failure=true,
    )
    // Wait past the router move, plus one round so the task parks at the mutex.
    let mut switched = false
    while !switched {
      @async.pause()
      switched = host.sessions[session_id].router.active_slot_id() ==
        "test/beta"
    }
    @async.pause()
    assert_eq(fs.files["/cetas-home/.cetas/settings.json"], seeded)
    acp_persist_mutex.release()
    try {
      let _ = task.wait()
    } catch {
      error => fail("the parked switch must settle: " + error.to_string())
    }
    let saved = @json.parse(fs.files["/cetas-home/.cetas/settings.json"]) catch {
      _ => fail("saved settings must parse")
    }
    assert_true(
      saved is Json::Object(fields) &&
      fields.get("model") is Some(Json::String("test/beta")) &&
      fields.get("providers") is Some(Json::Object({ .. })),
    )
  })
}

///|
async test "sidecar update waits on the process persist mutex" {
  let fs = FakeFs()
  let (host, _) = tk_host([], fs~)
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let sidecar_file = sidecar_path("/cetas-home", session_id)
  guard fs.files.contains(sidecar_file) else {
    fail("session/new must write the sidecar")
  }
  @async.with_task_group(group => {
    acp_persist_mutex.acquire() catch {
      _ => fail("the test task must acquire the persist mutex")
    }
    let task = group.spawn(
      () => {
        host.update_session_sidecar(session_id, host.sessions[session_id], [
          "ghost",
        ])
      },
      allow_failure=true,
    )
    @async.pause()
    @async.pause()
    let parked = @json.parse(fs.files[sidecar_file]) catch {
      _ => fail("sidecar must parse")
    }
    guard parked is Json::Object(before) else {
      fail("sidecar must be an object")
    }
    assert_true(before.get("mcp_servers") is Some(Json::Array([])))
    acp_persist_mutex.release()
    try {
      let _ = task.wait()
    } catch {
      error =>
        fail("the parked sidecar update must settle: " + error.to_string())
    }
    let merged = @json.parse(fs.files[sidecar_file]) catch {
      _ => fail("sidecar must parse")
    }
    guard merged is Json::Object(after) else {
      fail("sidecar must be an object")
    }
    assert_true(
      after.get("mcp_servers") is Some(Json::Array([Json::String("ghost")])),
    )
  })
}

///|
/// Two concurrent switches serialize into one complete write (providers subtree kept, one selection).
async test "concurrent set_config_option calls leave one complete selection write" {
  let fs = FakeFs()
  fs.files["/cetas-home/.cetas/settings.json"] = "{\"providers\":{\"kimi\":{}}}"
  let (host, _) = tk_host([], fs~)
  let client_a = FakeAcpClient::FakeAcpClient()
  let client_b = FakeAcpClient::FakeAcpClient()
  let a = tk_open_session(host, client_a)
  let b = tk_open_session(host, client_b)
  @async.with_task_group(group => {
    let task_a = group.spawn(
      () => {
        host.handle_set_config_option(fake_acp_context(client_a), {
          session_id: a,
          config_id: "model",
          value: @acp.SessionConfigValue::ValueId("test/beta"),
          meta: Omitted,
        })
      },
      allow_failure=true,
    )
    let task_b = group.spawn(
      () => {
        host.handle_set_config_option(fake_acp_context(client_b), {
          session_id: b,
          config_id: "effort",
          value: @acp.SessionConfigValue::ValueId("high"),
          meta: Omitted,
        })
      },
      allow_failure=true,
    )
    try {
      let _ = task_a.wait()
    } catch {
      error => fail("switch A must settle: " + error.to_string())
    }
    try {
      let _ = task_b.wait()
    } catch {
      error => fail("switch B must settle: " + error.to_string())
    }
  })
  assert_eq(host.sessions[a].router.active_slot_id(), "test/beta")
  assert_eq(host.sessions[b].router.active_effort(), Some("high"))
  let saved = @json.parse(fs.files["/cetas-home/.cetas/settings.json"]) catch {
    _ => fail("saved settings must parse")
  }
  guard saved is Json::Object(fields) else {
    fail("saved settings must be an object")
  }
  assert_true(fields.get("providers") is Some(Json::Object({ .. })))
  let beta_complete = fields.get("model") is Some(Json::String("test/beta")) &&
    fields.get("reasoning_effort") is None
  let alpha_complete = fields.get("model") is Some(Json::String("test/alpha")) &&
    fields.get("reasoning_effort") is Some(Json::String("high"))
  assert_true(beta_complete || alpha_complete)
}

// ------------------------------------------- W5: refresh exactly-once audit

///|
/// Exactly one update per session per refresh (B's vanished beta falls back per replace_provider_slots).
async test "refresh pushes exactly one update per session from its own router view" {
  let fs = FakeFs()
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
  let client_a = FakeAcpClient::FakeAcpClient()
  let client_b = FakeAcpClient::FakeAcpClient()
  let a = host.handle_new_session(
      fake_acp_context(client_a),
      tk_new_session_params(),
    ).session_id
  let b = host.handle_new_session(
      fake_acp_context(client_b),
      tk_new_session_params(),
    ).session_id
  // Diverge routers directly — set_config_option would push its own update and pollute the count.
  host.sessions[a].router.select_effort("test/alpha", "high")
  host.sessions[b].router.switch_slot("test/beta")
  assert_eq(client_a.sent.length(), 0)
  assert_eq(client_b.sent.length(), 0)
  host.refresh_model_lists()
  assert_eq(client_a.sent.length(), 1)
  assert_eq(client_b.sent.length(), 1)
  assert_eq(client_a.sent[0].session_id, a)
  assert_eq(client_b.sent[0].session_id, b)
  match client_a.sent[0].update {
    ConfigOptionUpdate({ config_options, .. }) => {
      match tk_find_option(config_options, "model") {
        Some(select) => {
          assert_eq(select.current_value, "test/alpha")
          assert_eq(tk_ungrouped(select.options).length(), 3)
        }
        None => fail("A's pushed options must include the model arm")
      }
      match tk_find_option(config_options, "effort") {
        Some(select) => assert_eq(select.current_value, "high")
        None => fail("A's pushed options must include the effort arm")
      }
    }
    _ => fail("expected A's config option update")
  }
  match client_b.sent[0].update {
    ConfigOptionUpdate({ config_options, .. }) => {
      match tk_find_option(config_options, "model") {
        Some(select) => {
          assert_eq(select.current_value, "test/alpha")
          assert_eq(tk_ungrouped(select.options).length(), 3)
        }
        None => fail("B's pushed options must include the model arm")
      }
      match tk_find_option(config_options, "effort") {
        Some(select) => assert_eq(select.current_value, "low")
        None => fail("B's pushed options must include the effort arm")
      }
    }
    _ => fail("expected B's config option update")
  }
}

// --------------------------------------- W5: rate-limit monitor exit audit

///|
priv struct TkMonitorTicks {
  mut count : Int
}

///|
/// The monitor must stop after on_shutdown, or every close leaks a parked poller on the mcp group.
async test "rate-limit monitor stops after lifecycle shutdown" {
  let ticks = TkMonitorTicks::{ count: 0, }
  let rl_guard = @ratelimit.RateLimitGuard(poll_interval_ms=1, sleep_ms=async fn(
    _ms : Int,
  ) {
    ticks.count += 1
    @async.sleep(1)
  })
  @async.with_task_group(group => {
    rl_guard.spawn_monitor(group)
    while ticks.count < 3 {
      @async.pause()
    }
    (rl_guard as &@posoco.Lifecycle).on_shutdown()
    let settled = ticks.count
    @async.sleep(20)
    assert_eq(ticks.count, settled)
  })
}

// --------------------------------------------- W9: session modes (plan mode)

///|
/// Plan wiring minus the review: `exit_plan_mode` parks the plan at `ReadyForApproval` (set_mode start state).
fn tk_spawn_session_plan_noreview(
  model : &@posoco.ModelPort,
  process_cwd : String,
) -> async (String, @acp.NewSessionParams) -> Result[SessionHandle, String] {
  fn(
    _session_id : String,
    params : @acp.NewSessionParams,
  ) -> Result[SessionHandle, String] {
    let cwd = if params.cwd.length() > 0 { params.cwd } else { process_cwd }
    try {
      let bridge = @ext_acp.AcpBridge()
      let event_bus = @devkit.EventBus()
      let policy = @permission.PermissionPolicy(
        @permission.WorkspaceWrite,
        approval=Some(bridge as &@permission.ApprovalSource),
        bus=Some(event_bus),
      )
      let plan_mode = @plan.PlanMode(
        config={
          ..@plan.PlanModeConfig::default(),
          allowed_tools: ["read", "glob", "grep", "ask_question"],
          allow_model_entry: true,
        },
        bus=Some(event_bus),
      )
      let agent = @posoco.Agent(
        exts=[
          @posoco.tk_ext(id="model", model=Some(model)),
          @posoco.tk_ext(id="io", sessions=[
            @posoco.RecordingSessionStore::RecordingSessionStore()
            as &@posoco.SessionStore,
          ]),
          bridge,
          policy,
          plan_mode,
        ],
        config=@posoco.tk_config(),
      )
      Ok({
        bridge,
        router: tk_router(),
        agent,
        cwd,
        plan: plan_mode,
        permission: policy,
        fs_delegate: None,
        context: None,
        in_flight: None,
        turn_lock: @async.Mutex::Mutex(),
        last_mode_id: "default",
      })
    } catch {
      error => Err(error.to_string())
    }
  }
}

///|
fn tk_mode_pushes(client : FakeAcpClient, mode_id : String) -> Int {
  let mut count = 0
  for frame in client.sent {
    match frame.update {
      CurrentModeUpdate(update) =>
        if update.current_mode_id == mode_id {
          count += 1
        }
      _ => ()
    }
  }
  count
}

///|
fn tk_assert_modes(
  state : @acp.SessionModeState,
  current : String,
) -> Unit raise {
  assert_eq(state.current_mode_id, current)
  assert_eq(state.available_modes.length(), 2)
  assert_true(
    state.available_modes[0] is { id: "default", name: "Default", .. },
  )
  assert_true(state.available_modes[1] is { id: "plan", name: "Plan", .. })
}

///|
async test "session results advertise the default and plan modes" {
  let store = @fs_session.JsonlSessionStore(tk_temp_root("w9-modes"))
  let fs = FakeFs()
  let (host, _) = tk_host(
    [@posoco.Respond(@posoco.tk_stop_response("history"))],
    fs~,
    store~,
  )
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let new_result = host.handle_new_session(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    tk_new_session_params(),
  )
  guard new_result.modes is Value(new_modes) else {
    fail("new must advertise modes")
  }
  tk_assert_modes(new_modes, "default")
  let turn = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt("persist me"),
    meta: Omitted,
  })
  assert_true(turn.stop_reason is EndTurn)
  // Mode is runtime state, deliberately absent from the sidecar.
  let loaded = host.handle_load_session(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    tk_load_params(session_id),
  )
  guard loaded.modes is Value(load_modes) else {
    fail("load must advertise modes")
  }
  tk_assert_modes(load_modes, "default")
  let resumed = host.handle_resume_session(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    tk_resume_params(session_id),
  )
  guard resumed.modes is Value(resume_modes) else {
    fail("resume must advertise modes")
  }
  tk_assert_modes(resume_modes, "default")
  let forked = host.handle_fork_session(
    fake_acp_context(FakeAcpClient::FakeAcpClient()),
    tk_fork_params(session_id),
  )
  guard forked.modes is Value(fork_modes) else {
    fail("fork must advertise modes")
  }
  tk_assert_modes(fork_modes, "default")
}

///|
async test "set_mode plan enters planning, pushes the mode, and gates writes" {
  let (host, _) = tk_host([])
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let result = host.handle_set_mode(fake_acp_context(client), {
    session_id,
    mode_id: "plan",
    meta: Omitted,
  })
  assert_true(result.meta is Omitted)
  match host.sessions[session_id].plan.status() {
    Planning => ()
    other => fail("set_mode plan must reach Planning, got \{other}")
  }
  assert_eq(tk_mode_pushes(client, "plan"), 1)
  assert_eq(tk_mode_pushes(client, "default"), 0)
  let write : @posoco.ToolCall = @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("w9-write"),
    name: @posoco.ToolName::unchecked("write"),
    arguments: Json::null(),
  }
  match host.sessions[session_id].plan.before_tool(write) {
    @posoco.ToolDecision::Reject(reason~) =>
      assert_true(reason.contains("plan mode"))
    _ => fail("write must be gated while plan mode is on")
  }
  let read : @posoco.ToolCall = @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("w9-read"),
    name: @posoco.ToolName::unchecked("read"),
    arguments: Json::null(),
  }
  assert_true(
    host.sessions[session_id].plan.before_tool(read)
    is @posoco.ToolDecision::Reject(_),
  )
  let exit_call : @posoco.ToolCall = @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("w9-exit"),
    name: @posoco.ToolName::unchecked("exit_plan_mode"),
    arguments: Json::null(),
  }
  assert_true(
    host.sessions[session_id].plan.before_tool(exit_call)
    is @posoco.ToolDecision::Approve(_),
  )
}

///|
async test "set_mode default leaves plan mode directly, review-free" {
  let model = @posoco.ScriptedModel([
    @posoco.Respond(
      @posoco.tk_tool_call_response(
        "enter_plan_mode",
        "pe1",
        Json::object(Map::from_array([])),
      ),
    ),
    @posoco.Respond(
      @posoco.tk_tool_call_response(
        "exit_plan_mode",
        "px1",
        Json::object(
          Map::from_array([
            ("name", Json::string("pending plan")),
            ("plan", Json::string("1. do it")),
          ]),
        ),
      ),
    ),
    @posoco.Respond(@posoco.tk_stop_response("submitted")),
    @posoco.Respond(@posoco.tk_stop_response("after exit")),
  ])
  let host = CetasAcpHost::of(
    spawn_session=tk_spawn_session_plan_noreview(model, "/"),
    home="/cetas-home",
    fs=FakeFs(),
  )
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let turn = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt("draft a plan"),
    meta: Omitted,
  })
  assert_true(turn.stop_reason is EndTurn)
  match host.sessions[session_id].plan.status() {
    ReadyForApproval(..) => ()
    other => fail("no-review exit must stay pending, got \{other}")
  }
  assert_eq(tk_mode_pushes(client, "plan"), 1)
  // Re-entry while pending normalizes to fresh Planning, no extra push.
  ignore(
    host.handle_set_mode(fake_acp_context(client), {
      session_id,
      mode_id: "plan",
      meta: Omitted,
    }),
  )
  match host.sessions[session_id].plan.status() {
    Planning => ()
    other => fail("set_mode plan must normalize to Planning, got \{other}")
  }
  assert_eq(tk_mode_pushes(client, "plan"), 1)
  assert_eq(tk_mode_pushes(client, "default"), 0)
  ignore(
    host.handle_set_mode(fake_acp_context(client), {
      session_id,
      mode_id: "default",
      meta: Omitted,
    }),
  )
  match host.sessions[session_id].plan.status() {
    Off => ()
    other => fail("set_mode default must exit directly, got \{other}")
  }
  assert_eq(client.asked.length(), 0)
  assert_eq(tk_mode_pushes(client, "plan"), 1)
  assert_eq(tk_mode_pushes(client, "default"), 1)
}

///|
async test "set_mode rejects unknown modes and unknown sessions" {
  let (host, _) = tk_host([])
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let bad_mode : Result[@acp.SetSessionModeResult, @acp.HandlerError] = Ok(
    host.handle_set_mode(fake_acp_context(client), {
      session_id,
      mode_id: "turbo",
      meta: Omitted,
    }),
  ) catch {
    error => Err(error)
  }
  match bad_mode {
    Err(InvalidParams(message~)) =>
      assert_true(message.contains("unknown mode"))
    _ => fail("unknown mode must reject as invalid params")
  }
  let bad_session : Result[@acp.SetSessionModeResult, @acp.HandlerError] = Ok(
    host.handle_set_mode(fake_acp_context(client), {
      session_id: "cetas-404",
      mode_id: "plan",
      meta: Omitted,
    }),
  ) catch {
    error => Err(error)
  }
  match bad_session {
    Err(InvalidParams(message~)) =>
      assert_true(message.contains("unknown session"))
    _ => fail("unknown session must reject as invalid params")
  }
}

///|
async test "a model-entered plan mode reaches the client at the epilogue" {
  let (host, _) = tk_host_plan([
    @posoco.Respond(
      @posoco.tk_tool_call_response(
        "enter_plan_mode",
        "pe1",
        Json::object(Map::from_array([])),
      ),
    ),
    @posoco.Respond(@posoco.tk_stop_response("researching")),
  ])
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let result = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt("plan please"),
    meta: Omitted,
  })
  assert_true(result.stop_reason is EndTurn)
  match host.sessions[session_id].plan.status() {
    Planning => ()
    other =>
      fail("the model must be planning after its own entry, got \{other}")
  }
  assert_eq(tk_mode_pushes(client, "plan"), 1)
  assert_eq(tk_mode_pushes(client, "default"), 0)
}

///|
async test "an approved exit pushes the mode back to default at the epilogue" {
  let (host, _) = tk_host_plan([
    @posoco.Respond(
      @posoco.tk_tool_call_response(
        "enter_plan_mode",
        "pe1",
        Json::object(Map::from_array([])),
      ),
    ),
    @posoco.Respond(@posoco.tk_stop_response("planning")),
    @posoco.Respond(
      @posoco.tk_tool_call_response(
        "exit_plan_mode",
        "px1",
        Json::object(
          Map::from_array([
            ("name", Json::string("my plan")),
            ("plan", Json::string("1. do it")),
          ]),
        ),
      ),
    ),
    @posoco.Respond(@posoco.tk_stop_response("approved")),
  ])
  let client = FakeAcpClient::FakeAcpClient(
    reply=tk_plan_reply(PLAN_OPTION_APPROVE),
  )
  let session_id = tk_open_session(host, client)
  let first = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt("plan it"),
    meta: Omitted,
  })
  assert_true(first.stop_reason is EndTurn)
  assert_eq(tk_mode_pushes(client, "plan"), 1)
  let second = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt("submit"),
    meta: Omitted,
  })
  assert_true(second.stop_reason is EndTurn)
  match host.sessions[session_id].plan.status() {
    Off => ()
    other => fail("approval must leave plan mode, got \{other}")
  }
  assert_eq(tk_mode_pushes(client, "default"), 1)
  assert_eq(client.asked.length(), 1)
}

// ------------------------------------------------------- workspace delegation

///|
async test "CETAS_DELEGATE_FS resolves host and local, falling back to local" {
  assert_true(resolve_startup_delegation_mode(None) is DelegateFsMode::Local)
  assert_true(
    resolve_startup_delegation_mode(Some("host")) is DelegateFsMode::Host,
  )
  assert_true(
    resolve_startup_delegation_mode(Some("local")) is DelegateFsMode::Local,
  )
  assert_true(
    resolve_startup_delegation_mode(Some("HOST")) is DelegateFsMode::Local,
  )
  assert_true(
    resolve_startup_delegation_mode(Some("bogus")) is DelegateFsMode::Local,
  )
}

///|
async test "an attached delegate rides host reads and writes with the session stamp" {
  let client = FakeAcpClient::FakeAcpClient()
  client.fs_enabled = true
  client.files["/ws/notes.txt"] = "host copy"
  let disk = FakeFs()
  disk.files["/ws/notes.txt"] = "local copy"
  let delegate = AcpDelegateFs::AcpDelegateFs(
    local_fs=disk as &@workspace.WorkspaceFs,
    session_id="cetas-1",
  )
  let fs : &@workspace.WorkspaceFs = delegate
  delegate.attach(context=fake_acp_context(client))
  assert_eq(
    fs.read_file("/ws/notes.txt") catch {
      _ => fail("host read")
    },
    "host copy",
  )
  assert_eq(client.fs_reads.length(), 1)
  assert_eq(client.fs_reads[0].session_id, "cetas-1")
  assert_eq(client.fs_reads[0].path, "/ws/notes.txt")
  assert_true(client.fs_reads[0].line is Omitted)
  fs.write_file("/ws/out.txt", "written") catch {
    _ => fail("host write")
  }
  assert_eq(client.fs_writes.length(), 1)
  assert_eq(client.fs_writes[0].session_id, "cetas-1")
  assert_eq(client.fs_writes[0].content, "written")
  assert_false(disk.files.contains("/ws/out.txt"))
  assert_eq(client.files["/ws/out.txt"], "written")
}

///|
async test "a client without fs capability degrades the delegate to local" {
  let client = FakeAcpClient::FakeAcpClient()
  let disk = FakeFs()
  disk.files["/ws/notes.txt"] = "local copy"
  let delegate = AcpDelegateFs::AcpDelegateFs(
    local_fs=disk as &@workspace.WorkspaceFs,
    session_id="cetas-1",
  )
  let fs : &@workspace.WorkspaceFs = delegate
  delegate.attach(context=fake_acp_context(client))
  assert_eq(
    fs.read_file("/ws/notes.txt") catch {
      _ => fail("fallback read")
    },
    "local copy",
  )
  fs.write_file("/ws/out.txt", "written") catch {
    _ => fail("fallback write")
  }
  assert_eq(disk.files["/ws/out.txt"], "written")
  assert_eq(client.fs_reads.length(), 1)
  assert_eq(client.fs_writes.length(), 1)
}

///|
async test "a failed host fs call falls back to the local file" {
  let client = FakeAcpClient::FakeAcpClient()
  client.fs_enabled = true
  let disk = FakeFs()
  disk.files["/ws/only-local.txt"] = "local copy"
  let delegate = AcpDelegateFs::AcpDelegateFs(
    local_fs=disk as &@workspace.WorkspaceFs,
    session_id="cetas-1",
  )
  let fs : &@workspace.WorkspaceFs = delegate
  delegate.attach(context=fake_acp_context(client))
  assert_eq(
    fs.read_file("/ws/only-local.txt") catch {
      _ => fail("fallback read")
    },
    "local copy",
  )
}

///|
async test "an unattached delegate runs purely local" {
  let client = FakeAcpClient::FakeAcpClient()
  client.fs_enabled = true
  client.files["/ws/notes.txt"] = "host copy"
  let disk = FakeFs()
  disk.files["/ws/notes.txt"] = "local copy"
  let delegate = AcpDelegateFs::AcpDelegateFs(
    local_fs=disk as &@workspace.WorkspaceFs,
    session_id="cetas-1",
  )
  let fs : &@workspace.WorkspaceFs = delegate
  assert_eq(
    fs.read_file("/ws/notes.txt") catch {
      _ => fail("pre read")
    },
    "local copy",
  )
  delegate.attach(context=fake_acp_context(client))
  assert_eq(
    fs.read_file("/ws/notes.txt") catch {
      _ => fail("attached read")
    },
    "host copy",
  )
  delegate.detach()
  assert_eq(
    fs.read_file("/ws/notes.txt") catch {
      _ => fail("post read")
    },
    "local copy",
  )
  assert_eq(client.fs_reads.length(), 1)
}

///|
async test "directory-shaped operations stay local on the delegate" {
  let client = FakeAcpClient::FakeAcpClient()
  client.fs_enabled = true
  let disk = FakeFs()
  disk.files["/ws/notes.txt"] = "content"
  let delegate = AcpDelegateFs::AcpDelegateFs(
    local_fs=disk as &@workspace.WorkspaceFs,
    session_id="cetas-1",
  )
  let fs : &@workspace.WorkspaceFs = delegate
  delegate.attach(context=fake_acp_context(client))
  assert_true(fs.exists("/ws/notes.txt"))
  assert_true(
    fs.kind("/ws/notes.txt", follow_symlink=true)
    is @workspace.WorkspaceFileKind::File,
  )
  assert_eq(fs.realpath("/ws/notes.txt"), "/ws/notes.txt")
  assert_eq(fs.readdir("/ws", include_hidden=false).length(), 0)
  // Atomic writes have no ACP destination and stay local.
  fs.write_file_atomic("/ws/atomic.txt", "x")
  assert_eq(disk.files["/ws/atomic.txt"], "x")
  assert_eq(client.fs_reads.length(), 0)
  assert_eq(client.fs_writes.length(), 0)
}

///|
async test "session assembly wires the fs delegate by the resolved mode" {
  let fs = FakeFs()
  fs.files["/cetas-home/.cetas/settings.json"] = "{\"providers\":{\"opencode\":{\"api_key\":\"sk-zen-test\"}}}"
  let platform = build_platform(
    home="/cetas-home",
    cwd="/",
    fs,
    mcp_group=None,
    mcp_mode=@mcp.LoadMode::Lazy,
  ) catch {
    error => fail("platform assembly must succeed: " + error.to_string())
  }
  let plain = build_session_agent(platform~, cwd="/", session_id="cetas-a") catch {
    error => fail("local assembly must succeed: " + error.to_string())
  }
  assert_true(plain.fs_delegate is None)
  let delegated_platform = build_platform(
    home="/cetas-home",
    cwd="/",
    fs,
    mcp_group=None,
    mcp_mode=@mcp.LoadMode::Lazy,
    delegation=DelegateFsMode::Host,
  ) catch {
    error => fail("platform assembly must succeed: " + error.to_string())
  }
  let delegated = build_session_agent(
    platform=delegated_platform,
    cwd="/",
    session_id="cetas-b",
  ) catch {
    error => fail("host assembly must succeed: " + error.to_string())
  }
  match delegated.fs_delegate {
    Some(delegate) => {
      let wfs : &@workspace.WorkspaceFs = delegate
      let client = FakeAcpClient::FakeAcpClient()
      client.fs_enabled = true
      client.files["/ws/x.txt"] = "host copy"
      fs.files["/ws/x.txt"] = "local copy"
      assert_eq(
        wfs.read_file("/ws/x.txt") catch {
          _ => fail("pre attach")
        },
        "local copy",
      )
      set_handle_context(delegated, fake_acp_context(client))
      assert_eq(
        wfs.read_file("/ws/x.txt") catch {
          _ => fail("attached")
        },
        "host copy",
      )
      clear_handle_context(delegated)
      assert_eq(
        wfs.read_file("/ws/x.txt") catch {
          _ => fail("post retire")
        },
        "local copy",
      )
      assert_eq(client.fs_reads.length(), 1)
      assert_eq(client.fs_reads[0].session_id, "cetas-b")
    }
    None => fail("host mode must wire the delegate")
  }
}

// --------------------------------- R4-C: host profile dispatch (lody / paseo)

///|
/// Name-only stdio declaration; the dead command degrades to a warning (W2 contract).
fn tk_profile_server(name : String) -> @acp.McpServer {
  Stdio({
    name,
    command: "/nonexistent-cetas-mcp-binary",
    args: [],
    env: [],
    meta: Omitted,
  })
}

///|
/// Assemble like the production `spawn_session` closure: detect the profile, pass both to the builder.
async fn tk_spawn_with_profile(
  platform~ : Platform,
  cwd~ : String,
  injected~ : Array[@acp.McpServer],
) -> SessionHandle {
  build_session_agent(
    platform~,
    cwd~,
    mcp_servers=injected,
    host_profile=detect_host_profile(acp_mcp_server_names(injected)),
  )
}

///|
async test "lody injection mounts the lody delegation prompt section" {
  let platform = tk_mcp_platform() catch {
    error => fail("platform assembly must succeed: " + error.to_string())
  }
  let injected = [tk_profile_server("lody")]
  let _ = tk_spawn_with_profile(platform~, cwd="/w4-lody", injected~) catch {
    error => fail("lody session must assemble: " + error.to_string())
  }
  let profile = detect_host_profile(acp_mcp_server_names(injected))
  assert_true(profile is Lody)
  let prompt = compose_system_prompt(Lody, cwd="/w4-lody")
  assert_true(prompt.contains(@lody_kit.prompt_section()))
  assert_true(prompt.contains("## Delegated tasks (lody)"))
}

///|
async test "paseo injection mounts the paseo orchestration prompt section" {
  let platform = tk_mcp_platform() catch {
    error => fail("platform assembly must succeed: " + error.to_string())
  }
  let injected = [tk_profile_server("paseo")]
  let _ = tk_spawn_with_profile(platform~, cwd="/w4-paseo", injected~) catch {
    error => fail("paseo session must assemble: " + error.to_string())
  }
  let profile = detect_host_profile(acp_mcp_server_names(injected))
  assert_true(profile is Paseo)
  let prompt = compose_system_prompt(Paseo, cwd="/w4-paseo")
  assert_true(prompt.contains(@paseo_kit.prompt_section()))
  assert_true(prompt.contains("## Delegated agents (paseo)"))
}

///|
async test "dual injection resolves to lody regardless of declaration order" {
  let platform = tk_mcp_platform() catch {
    error => fail("platform assembly must succeed: " + error.to_string())
  }
  let lody_first = [tk_profile_server("lody"), tk_profile_server("paseo")]
  let paseo_first = [tk_profile_server("paseo"), tk_profile_server("lody")]
  let _ = tk_spawn_with_profile(
    platform~,
    cwd="/w4-both-a",
    injected=lody_first,
  ) catch {
    error => fail("dual session must assemble: " + error.to_string())
  }
  let _ = tk_spawn_with_profile(
    platform~,
    cwd="/w4-both-b",
    injected=paseo_first,
  ) catch {
    error => fail("dual session must assemble: " + error.to_string())
  }
  let a = detect_host_profile(acp_mcp_server_names(lody_first))
  let b = detect_host_profile(acp_mcp_server_names(paseo_first))
  assert_true(a is Lody)
  assert_true(b is Lody)
  let prompt = compose_system_prompt(a, cwd="/w4-both-a")
  assert_true(prompt.contains("## Delegated tasks (lody)"))
  assert_false(prompt.contains("paseo"))
}

///|
async test "no injection keeps the generic profile" {
  let platform = tk_mcp_platform() catch {
    error => fail("platform assembly must succeed: " + error.to_string())
  }
  let _ = build_session_agent(platform~, cwd="/w4-plain") catch {
    error => fail("plain session must assemble: " + error.to_string())
  }
  assert_true(detect_host_profile([]) is Generic)
  assert_eq(
    compose_system_prompt(Generic, cwd="/w4-plain"),
    @cetas_core.cetas_system_prompt(cwd="/w4-plain"),
  )
}

///|
test "profile detection is pure and total" {
  assert_true(detect_host_profile([]) is Generic)
  assert_true(detect_host_profile(["editor-helper"]) is Generic)
  assert_true(detect_host_profile(["lody"]) is Lody)
  assert_true(detect_host_profile(["paseo"]) is Paseo)
  assert_true(detect_host_profile(["paseo", "lody"]) is Lody)
  assert_true(detect_host_profile(["lody", "paseo"]) is Lody)
  assert_eq(
    acp_mcp_server_names([
      tk_profile_server("stdio-name"),
      Http({
        name: "http-name",
        url: "https://mcp.example.com/mcp",
        headers: [],
        meta: Omitted,
      }),
      Sse({
        name: "sse-name",
        url: "https://old.example.com/sse",
        headers: [],
        meta: Omitted,
      }),
    ]),
    ["stdio-name", "http-name", "sse-name"],
  )
  assert_true(host_prompt_section(Generic) is None)
  assert_eq(host_prompt_section(Lody), Some(@lody_kit.prompt_section()))
  assert_eq(host_prompt_section(Paseo), Some(@paseo_kit.prompt_section()))
}

// ------------------------------------------------------------- debug taps

///|
async fn tk_mcp_platform_fs(
  debug? : DebugTaps = { catalog: false, wire: false, },
) -> (Platform, FakeFs) raise @posoco.CompositionError {
  let fs = FakeFs()
  fs.files["/cetas-home/.cetas/settings.json"] = "{\"providers\":{\"opencode\":{\"api_key\":\"sk-zen-test\"}}}"
  let platform = build_platform(
    home="/cetas-home",
    cwd="/",
    fs,
    mcp_group=None,
    mcp_mode=@mcp.LoadMode::Lazy,
    debug~,
  )
  (platform, fs)
}

///|
test "debug flag parsing accepts only 1" {
  assert_false(parse_debug_flag(None))
  assert_true(parse_debug_flag(Some("1")))
  assert_false(parse_debug_flag(Some("0")))
  assert_false(parse_debug_flag(Some("")))
  assert_false(parse_debug_flag(Some("true")))
  assert_false(parse_debug_flag(Some("yes")))
}

///|
async test "an unrecognized debug flag value warns and stays off" {
  assert_false(
    resolve_debug_flag(name="CETAS_DEBUG_WIRE", env_value=Some("verbose")),
  )
  assert_false(resolve_debug_flag(name="CETAS_DEBUG_WIRE", env_value=None))
  assert_true(resolve_debug_flag(name="CETAS_DEBUG_WIRE", env_value=Some("1")))
  assert_true(
    resolve_debug_flag(name="CETAS_DEBUG_MCP_CATALOG", env_value=Some("1")),
  )
}

///|
/// Catalog dump well-formedness: a JSON object with a fully-keyed `tools` array.
fn tk_assert_catalog_tools(text : String) -> Array[Json] raise {
  let parsed = @json.parse(text)
  let tools = match parsed {
    Json::Object(fields) =>
      match fields.get("tools") {
        Some(Json::Array(items)) => items
        _ => fail("catalog dump must carry a tools array")
      }
    _ => fail("catalog dump must be a JSON object")
  }
  assert_true(tools.length() > 0)
  for tool in tools {
    guard tool is Json::Object(entry) else {
      fail("each catalog entry must be an object")
    }
    assert_true(
      entry.contains("name") &&
      entry.contains("description") &&
      entry.contains("input_schema") &&
      entry.contains("source"),
    )
  }
  tools
}

///|
async test "the catalog dump lands after an injected session assembly" {
  let (platform, fs) = tk_mcp_platform_fs(debug={ catalog: true, wire: false, }) catch {
    error => fail("platform assembly must succeed: " + error.to_string())
  }
  let injected : Array[@acp.McpServer] = [
    Stdio({
      name: "ghost",
      command: "/nonexistent-cetas-mcp-binary",
      args: [],
      env: [],
      meta: Omitted,
    }),
  ]
  let session = build_session_agent(
    platform~,
    cwd="/w21-a",
    session_id="cetas-w21cat",
    mcp_servers=injected,
    host_profile=HostProfile::Lody,
  ) catch {
    error =>
      fail("injected session assembly must succeed: " + error.to_string())
  }
  assert_eq(session.cwd, "/w21-a")
  let text = match
    fs.files.get("/cetas-home/.cetas/debug/cetas-w21cat-catalog.json") {
    Some(text) => text
    None => fail("the catalog dump must exist for an injected session")
  }
  assert_true(text.contains("\"host_profile\": \"lody\""))
  assert_true(text.contains("\"mcp_source\": \"injected\""))
  assert_false(text.contains("\"source\": \"injected\""))
  let tools = tk_assert_catalog_tools(text)
  for tool in tools {
    guard tool is Json::Object(entry) else { fail("unreachable") }
    match entry.get("source") {
      Some(Json::String("local")) => ()
      _ => fail("a connection-failed injection must label every tool local")
    }
  }
}

///|
async test "the catalog dump covers the discover fallback" {
  let (platform, fs) = tk_mcp_platform_fs(debug={ catalog: true, wire: false, }) catch {
    error => fail("platform assembly must succeed: " + error.to_string())
  }
  let session = build_session_agent(
    platform~,
    cwd="/w21-b",
    session_id="cetas-w21disc",
  ) catch {
    error => fail("discover fallback must compose: " + error.to_string())
  }
  assert_eq(session.cwd, "/w21-b")
  let text = match
    fs.files.get("/cetas-home/.cetas/debug/cetas-w21disc-catalog.json") {
    Some(text) => text
    None => fail("the catalog dump must exist for the discover fallback")
  }
  assert_true(text.contains("\"host_profile\": \"generic\""))
  assert_true(text.contains("\"mcp_source\": \"local\""))
  ignore(tk_assert_catalog_tools(text))
}

///|
async test "the wire log records the in direction and truncates prompts" {
  let fs = FakeFs()
  let (host, _) = tk_host(
    [@posoco.Respond(@posoco.tk_stop_response("w21 answer"))],
    fs~,
    wire_log=true,
  )
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let mut long = ""
  for _ in 0..<300 {
    long = long + "prompt-piece-0123456789 "
  }
  let turn = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt(long),
    meta: Omitted,
  })
  assert_true(turn.stop_reason is EndTurn)
  let text = match
    fs.files.get("/cetas-home/.cetas/debug/\{session_id}-wire.jsonl") {
    Some(text) => text
    None => fail("the wire file must exist for a wired session")
  }
  assert_true(text.contains("\"dir\":\"in\""))
  assert_true(text.contains("\"method\":\"session/new\""))
  assert_true(text.contains("\"method\":\"session/prompt\""))
  assert_true(text.contains("...(truncated)"))
  assert_false(text.contains(long))
  // Out direction: updates recorded once by the tap, then forwarded untouched.
  assert_true(text.contains("\"dir\":\"out\""))
  assert_true(text.contains("\"method\":\"session/update\""))
  assert_true(text.contains("\"ts\":"))
  assert_true(client.sent.length() > 0)
}

///|
async test "every wire record leads with a numeric epoch-ms ts" {
  let fs = FakeFs()
  let (host, _) = tk_host(
    [@posoco.Respond(@posoco.tk_stop_response("w22 answer"))],
    fs~,
    wire_log=true,
  )
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let turn = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt("w22 timing"),
    meta: Omitted,
  })
  assert_true(turn.stop_reason is EndTurn)
  let text = match
    fs.files.get("/cetas-home/.cetas/debug/\{session_id}-wire.jsonl") {
    Some(text) => text
    None => fail("the wire file must exist for a wired session")
  }
  let mut seen_in = false
  let mut seen_out = false
  for line in text.split("\n") {
    if line is "" {
      continue
    }
    let record : Json = @json.parse(line) catch { _ => Json::null() }
    guard record is Json::Object(fields) else {
      fail("each wire line must be a JSON object")
    }
    match fields.get("ts") {
      Some(Json::Number(ms, repr=_)) => assert_true(ms > 0.0)
      _ => fail("every wire record carries a numeric ts")
    }
    match fields.get("dir") {
      Some(Json::String("in")) => seen_in = true
      Some(Json::String("out")) => seen_out = true
      _ => ()
    }
  }
  assert_true(seen_in && seen_out)
}

///|
test "the wire masks url query and userinfo" {
  assert_eq(
    debug_mask_url(
      "https://user:secret@mcp.lody.dev/session/mcp?token=topsecret",
    ),
    "https://[masked]@mcp.lody.dev/session/mcp",
  )
  assert_eq(
    debug_mask_url("http://127.0.0.1:62370/mcp"),
    "http://127.0.0.1:62370/mcp",
  )
  assert_eq(
    debug_mask_url("https://mcp.example.dev"),
    "https://mcp.example.dev",
  )
}

///|
test "stop reasons map to the protocol wire strings" {
  assert_true(debug_stop_reason(EndTurn) is Json::String("end_turn"))
  assert_true(debug_stop_reason(Cancelled) is Json::String("cancelled"))
  assert_true(debug_stop_reason(MaxTokens) is Json::String("max_tokens"))
  assert_true(debug_stop_reason(Refusal) is Json::String("refusal"))
  assert_true(
    debug_stop_reason(MaxTurnRequests) is Json::String("max_turn_requests"),
  )
}

///|
async test "the wire's session/new record carries server transport detail" {
  let fs = FakeFs()
  let (host, _) = tk_host(
    [@posoco.Respond(@posoco.tk_stop_response("w22 servers"))],
    fs~,
    wire_log=true,
  )
  let client = FakeAcpClient::FakeAcpClient()
  let opened = host.handle_new_session(fake_acp_context(client), {
    cwd: "/w22-servers",
    additional_directories: Value(["/w22-extra"]),
    mcp_servers: [
      Http({
        name: "lody",
        url: "https://user:secret@mcp.lody.dev/session/mcp?token=topsecret",
        headers: [
          tk_header("Authorization", "Bearer tok"),
          tk_header("x-lody-task-tools", "1"),
        ],
        meta: Omitted,
      }),
      Stdio({
        name: "ghost",
        command: "/bin/ghost",
        args: ["--flag"],
        env: [],
        meta: Omitted,
      }),
    ],
    meta: Value(
      @json.parse("{\"lody_ctx\":{\"v\":2}}") catch {
        _ => Json::null()
      },
    ),
  })
  let text = match
    fs.files.get("/cetas-home/.cetas/debug/\{opened.session_id}-wire.jsonl") {
    Some(text) => text
    None => fail("the wire file must exist for a wired session")
  }
  let record : Json = @json.parse(text) catch { _ => Json::null() }
  guard record is Json::Object(fields) else {
    fail("the session/new record must be an object")
  }
  let params : Map[String, Json] = match fields.get("params") {
    Some(Json::Object(params)) => params
    _ => fail("params missing: " + text)
  }
  let servers : Array[Json] = match params.get("mcp_servers") {
    Some(Json::Array(items)) => items
    _ => fail("mcp_servers detail missing: " + text)
  }
  assert_eq(servers.length(), 2)
  guard servers[0] is Json::Object(http) else { fail("http entry missing") }
  assert_true(http.get("transport") is Some(Json::String("http")))
  match http.get("url") {
    Some(Json::String(url)) =>
      assert_eq(url, "https://[masked]@mcp.lody.dev/session/mcp")
    _ => fail("masked url missing")
  }
  match http.get("header_names") {
    Some(Json::Array(names)) => {
      assert_eq(names.length(), 2)
      assert_true(names[0] is Json::String("Authorization"))
      assert_true(names[1] is Json::String("x-lody-task-tools"))
    }
    _ => fail("header names missing")
  }
  // Only names and shapes: no credential, token, or header value on the wire.
  assert_false(text.contains("topsecret"))
  assert_false(text.contains("user:secret"))
  assert_false(text.contains("Bearer tok"))
  guard servers[1] is Json::Object(stdio) else { fail("stdio entry missing") }
  assert_true(stdio.get("transport") is Some(Json::String("stdio")))
  assert_true(stdio.get("command") is Some(Json::String("/bin/ghost")))
  assert_true(stdio.get("args") is Some(Json::Number(1.0, ..)))
  match params.get("additional_directories") {
    Some(Json::Object(dirs)) => {
      assert_true(dirs.get("present") is Some(Json::True))
      assert_true(dirs.get("count") is Some(Json::Number(1.0, ..)))
    }
    _ => fail("additional_directories shape missing")
  }
  match params.get("meta") {
    Some(Json::Object(meta)) => {
      assert_true(meta.get("present") is Some(Json::True))
      match meta.get("keys") {
        Some(Json::Array(keys)) =>
          assert_true(keys[0] is Json::String("lody_ctx"))
        _ => fail("meta keys missing")
      }
    }
    _ => fail("meta shape missing")
  }
}

///|
async test "the wire records the prompt settlement on success and error" {
  let fs = FakeFs()
  let (host, _) = tk_host(
    [@posoco.Respond(@posoco.tk_stop_response("w22 settle"))],
    fs~,
    wire_log=true,
  )
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let turn = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt("settle"),
    meta: Omitted,
  })
  assert_true(turn.stop_reason is EndTurn)
  // An erroring turn settles its own record: stop_reason null plus the error.
  let broken_id = tk_open_session(host, FakeAcpClient::FakeAcpClient())
  let outcome : Result[@acp.PromptResult, @acp.HandlerError] = Ok(
    host.handle_prompt(fake_acp_context(FakeAcpClient::FakeAcpClient()), {
      session_id: broken_id,
      prompt: tk_prompt("boom"),
      meta: Omitted,
    }),
  ) catch {
    error => Err(error)
  }
  assert_true(outcome is Err(_))
  let text = match
    fs.files.get("/cetas-home/.cetas/debug/\{session_id}-wire.jsonl") {
    Some(text) => text
    None => fail("the wire file must exist for a wired session")
  }
  let settlements : Array[Json] = []
  for line in text.split("\n") {
    if line is "" {
      continue
    }
    let record : Json = @json.parse(line) catch { _ => Json::null() }
    guard record is Json::Object(fields) else {
      fail("every wire line must be a JSON object")
    }
    match (fields.get("dir"), fields.get("method")) {
      (Some(Json::String("out")), Some(Json::String("session/prompt"))) =>
        settlements.push(record)
      _ => ()
    }
  }
  assert_eq(settlements.length(), 1)
  guard settlements[0] is Json::Object(out) else { fail("unreachable") }
  assert_true(out.get("stop_reason") is Some(Json::String("end_turn")))
  assert_true(out.get("ts") is Some(Json::Number(_, ..)))
  let broken_text = match
    fs.files.get("/cetas-home/.cetas/debug/\{broken_id}-wire.jsonl") {
    Some(text) => text
    None => fail("the broken session's wire file must exist")
  }
  let mut saw_error = false
  for line in broken_text.split("\n") {
    if line is "" {
      continue
    }
    let record : Json = @json.parse(line) catch { _ => Json::null() }
    guard record is Json::Object(fields) else {
      fail("every wire line must be a JSON object")
    }
    match (fields.get("dir"), fields.get("method")) {
      (Some(Json::String("out")), Some(Json::String("session/prompt"))) => {
        assert_true(fields.get("stop_reason") is Some(Json::Null))
        match fields.get("error") {
          Some(Json::String(message)) =>
            assert_true(message.contains("cetas-acp:"))
          _ => fail("error text missing on the failure branch")
        }
        saw_error = true
      }
      _ => ()
    }
  }
  assert_true(saw_error)
}

///|
async test "the native append path writes real files record by record" {
  let dir = @fs.tmpdir(prefix="cetas-acp-w22-")
  let path = dir + "/wire.jsonl"
  let native_fs = @workspace.NativeWorkspaceFs()
  debug_append_line(
    native_fs,
    native=true,
    dir~,
    path~,
    line="{\"dir\":\"in\",\"n\":1}",
  )
  debug_append_line(
    native_fs,
    native=true,
    dir~,
    path~,
    line="{\"dir\":\"out\",\"n\":2}",
  )
  match @workspace.read_file_result(native_fs, path) {
    Content(text) =>
      inspect(
        text,
        content=(
          #|{"dir":"in","n":1}
          #|{"dir":"out","n":2}
          #|
        ),
      )
    _ => fail("the native append must leave the records on disk")
  }
  @fs.remove(path) catch {
    _ => ()
  }
  @fs.rmdir(dir) catch {
    _ => ()
  }
}

///|
async test "a failed native append falls back to the workspace fs" {
  let fs = FakeFs()
  // A real file where the debug directory would live: native mkdir and the
  // append both fail, so the record must land through the fs seam instead.
  let base = @fs.tmpdir(prefix="cetas-acp-w22f-")
  let blocker = base + "/blocker"
  @fs.write_file(blocker, "x", create_mode=@fs.CreateMode::OpenOrCreate)
  let dir = blocker + "/debug"
  debug_append_line(
    fs,
    native=true,
    dir~,
    path=dir + "/wire.jsonl",
    line="record",
  )
  assert_true(fs.files.get(dir + "/wire.jsonl") is Some("record\n"))
  @fs.remove(blocker) catch {
    _ => ()
  }
  @fs.rmdir(base) catch {
    _ => ()
  }
}

///|
async test "the debug taps stay off by default" {
  let fs = FakeFs()
  let (host, _) = tk_host(
    [@posoco.Respond(@posoco.tk_stop_response("w21 quiet"))],
    fs~,
  )
  assert_false(host.wire_log)
  let client = FakeAcpClient::FakeAcpClient()
  let session_id = tk_open_session(host, client)
  let turn = host.handle_prompt(fake_acp_context(client), {
    session_id,
    prompt: tk_prompt("quiet turn"),
    meta: Omitted,
  })
  assert_true(turn.stop_reason is EndTurn)
  assert_false(fs.files.contains("/cetas-home/.cetas/debug"))
  assert_false(
    fs.files.contains("/cetas-home/.cetas/debug/\{session_id}-wire.jsonl"),
  )
  assert_false(
    fs.files.contains("/cetas-home/.cetas/debug/\{session_id}-catalog.json"),
  )
}

///|
fn parse_debug_flag(raw : String?) -> Bool {
  match raw {
    Some("1") => true
    _ => false
  }
}

///|
/// Whitebox/embedding constructor around a substituted session factory; tests
/// substitute fake refreshable factories to exercise `refresh_model_lists`.
fn CetasAcpHost::of(
  spawn_session~ : async (String, @acp.NewSessionParams) -> Result[
    SessionHandle,
    String,
  ],
  home~ : String,
  fs~ : &@workspace.WorkspaceFs,
  agent_version? : String = "0.1.0",
  refreshables? : Array[&@llm.RefreshableProviderFactory] = [],
  refresh_snapshot? : @cetas_core.ProviderCredentialSnapshot = @cetas_core.ProviderCredentialSnapshot::ProviderCredentialSnapshot(),
  session_store? : @fs_session.JsonlSessionStore = @fs_session.JsonlSessionStore(
    home + "/.cetas/sessions",
  ),
  process_cwd? : String = "/",
  wire_log? : Bool = false,
  native_append? : Bool = false,
) -> CetasAcpHost {
  {
    spawn_session,
    version: agent_version,
    home,
    fs,
    sessions: Map::from_array([]),
    session_store,
    process_cwd,
    catalogs: [],
    refreshables,
    refresh_snapshot,
    wire_log,
    wire_native_append: native_append,
  }
}
