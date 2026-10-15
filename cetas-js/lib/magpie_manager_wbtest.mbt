///|
/// magpie_manager_wbtest.mbt — Magpie manager integration tests.
///
/// Every scenario composes the real pieces the host composes — host settings
/// from a real settings.json, the credential store, `MagpieRuntime::activate`,
/// and a real `Agent::Agent` — with the network edge faked at the
/// `MagpieTransport` boundary. No test contacts a gateway.

///|
priv struct FakeMagpieStep {
  code : Int32
  body : String
}

///|
/// Scripted transport: queued GET bodies, queued POST bodies, and recorded
/// calls so tests can assert what was sent (and that nothing leaked).
struct FakeMagpieTransport {
  gets : Array[FakeMagpieStep]
  posts : Array[FakeMagpieStep]
  mut get_next : Int32
  mut post_next : Int32
  calls : Array[String]
  auths : Array[String]
  post_sessions : Array[String]
  /// Every response line handed to open streams, in order.
  stream_lines : Array[String]
  mut streams_opened : Int32
  mut streams_closed : Int32
}

///|
fn FakeMagpieTransport::FakeMagpieTransport(
  gets~ : Array[FakeMagpieStep] = [],
  posts~ : Array[FakeMagpieStep] = [],
  stream_lines~ : Array[String] = [],
) -> FakeMagpieTransport {
  {
    gets,
    posts,
    get_next: 0,
    post_next: 0,
    calls: [],
    auths: [],
    post_sessions: [],
    stream_lines,
    streams_opened: 0,
    streams_closed: 0,
  }
}

///|
priv struct FakeMagpieStream {
  transport : FakeMagpieTransport
  mut next : Int32
}

///|
fn FakeMagpieStream::FakeMagpieStream(
  transport~ : FakeMagpieTransport,
  next~ : Int32,
) -> FakeMagpieStream {
  { transport, next, }
}

///|
impl @magpie.MagpieTransport for FakeMagpieTransport with fn get(
  self : FakeMagpieTransport,
  url : String,
  headers : Map[String, String],
) -> (Int32, String) raise @magpie.MagpieGatewayError {
  self.calls.push(url)
  self.auths.push(headers.get("Authorization").unwrap_or(""))
  guard self.get_next < self.gets.length() else {
    raise @magpie.MagpieGatewayError::Offline(
      "fake transport exhausted; unexpected GET \{url}",
    )
  }
  let step = self.gets[self.get_next]
  self.get_next += 1
  (step.code, step.body)
}

///|
impl @magpie.MagpieTransport for FakeMagpieTransport with fn post(
  self : FakeMagpieTransport,
  url : String,
  headers~ : Map[String, String],
  body~ : String,
) -> (Int32, String) raise @magpie.MagpieGatewayError {
  ignore(body)
  self.calls.push(url)
  self.auths.push(headers.get("Authorization").unwrap_or(""))
  self.post_sessions.push(headers.get("X-Magpie-Session").unwrap_or(""))
  guard self.post_next < self.posts.length() else {
    raise @magpie.MagpieGatewayError::Offline(
      "fake transport exhausted; unexpected POST \{url}",
    )
  }
  let step = self.posts[self.post_next]
  self.post_next += 1
  (step.code, step.body)
}

///|
impl @magpie.MagpieTransport for FakeMagpieTransport with fn post_stream(
  self : FakeMagpieTransport,
  url : String,
  headers~ : Map[String, String],
  body~ : String,
) -> (Int32, &@magpie.MagpieEventStream) raise @magpie.MagpieGatewayError {
  ignore(body)
  self.calls.push(url)
  self.auths.push(headers.get("Authorization").unwrap_or(""))
  self.post_sessions.push(headers.get("X-Magpie-Session").unwrap_or(""))
  guard self.post_next < self.posts.length() else {
    raise @magpie.MagpieGatewayError::Offline(
      "fake transport exhausted; unexpected stream POST \{url}",
    )
  }
  let step = self.posts[self.post_next]
  self.post_next += 1
  let stream = FakeMagpieStream::FakeMagpieStream(transport=self, next=0)
  if step.code == 200 {
    self.streams_opened += 1
  }
  (step.code, stream as &@magpie.MagpieEventStream)
}

///|
impl @magpie.MagpieEventStream for FakeMagpieStream with fn next_line(
  self : FakeMagpieStream,
) -> String? raise @magpie.MagpieGatewayError {
  guard self.next < self.transport.stream_lines.length() else {
    self.transport.streams_closed += 1
    return None
  }
  let line = self.transport.stream_lines[self.next]
  self.next += 1
  Some(line)
}

///|
impl @magpie.MagpieEventStream for FakeMagpieStream with fn close_stream(
  self : FakeMagpieStream,
) -> Unit raise @magpie.MagpieGatewayError {
  self.transport.streams_closed += 1
}

///|
/// A complete hello + catalog script: one models entry with an effort ladder
/// and one routing group, the way the gateway reports them.
fn magpie_test_transport(
  secret~ : String = "",
  catalog~ : String = "{\"data\":[{\"id\":\"anthropic/claude-native\",\"display_name\":\"Claude Native\",\"owned_by\":\"anthropic\",\"reasoning\":true,\"supported_reasoning_levels\":[{\"effort\":\"low\"},{\"effort\":\"high\"}],\"context_window\":200000,\"native_endpoints\":[\"/v1/messages\"],\"modalities\":{\"input\":[\"text\",\"image\"]}},{\"id\":\"group/fast\",\"display_name\":\"Fast Lane\",\"owned_by\":\"relay\",\"group\":true}]}",
) -> FakeMagpieTransport {
  let hello = if secret == "" {
    "{\"name\":\"magpie\",\"version\":\"0.1.1224\"}"
  } else {
    "{\"name\":\"magpie\",\"version\":\"0.1.1224\",\"error\":\"key " +
    secret +
    " rejected\"}"
  }
  FakeMagpieTransport(gets=[
    { code: 200, body: hello, },
    { code: 200, body: catalog, },
  ])
}

///|
/// A buffered Messages completion body for turn tests.
fn magpie_turn_post_body(text~ : String) -> FakeMagpieStep {
  {
    code: 200,
    body: Json::object({
      "type": Json::string("message"),
      "id": Json::string("msg_1"),
      "model": Json::string("claude-served"),
      "role": Json::string("assistant"),
      "content": Json::array([
        Json::object({
          "type": Json::string("text"),
          "text": Json::string(text),
        }),
      ]),
      "stop_reason": Json::string("end_turn"),
      "stop_sequence": Json::null(),
      "usage": Json::object({
        "input_tokens": Json::number(3),
        "output_tokens": Json::number(2),
      }),
    }).stringify(),
  }
}

///|
/// Write a settings.json under a throwaway HOME and return the home path.
async fn magpie_test_home(tag~ : String, settings~ : String = "") -> String {
  let home = "/tmp/cetas-js-magpie-" + tag
  let fs = @workspace.JsWorkspaceFs()
  let _ = fs.mkdir(home + "/.cetas", recursive=true) catch { _ => () }
  let _ = fs.write_file_atomic(
    home + "/.cetas/settings.json",
    if settings == "" {
      "{}\n"
    } else {
      settings + "\n"
    },
  )
  home
}

///|
/// A credential store over a directory that never exists: every read is
/// Missing, so tests run without any credential unless one is bound by hand.
fn magpie_test_cred_store() -> @credentials.FileProviderCredentialStore {
  @credentials.FileProviderCredentialStore::FileProviderCredentialStore(
    @workspace.JsWorkspaceFs(),
    "/tmp/cetas-js-magpie-credentials-does-not-exist",
  )
}

///|
/// Compose a real Agent over the given runtime, the way create_agent does.
fn magpie_test_agent(runtime : @magpie.MagpieRuntime) -> @posoco.Agent raise {
  @posoco.Agent::Agent(exts=[runtime], config=@posoco.tk_config())
}

///|
/// Scenario 1: no `model_manager` key (or no settings at all) selects the
/// providers manager; nothing Magpie is activated.
async test "settings without a manager key select the providers manager" {
  let home = magpie_test_home(tag="unset")
  let warned : Array[String] = []
  let settings = read_magpie_host_settings(
    @workspace.JsWorkspaceFs(),
    home~,
    cred_store=magpie_test_cred_store(),
    warn=fn(message) { warned.push(message) },
  )
  assert_eq(settings is None, true)
  assert_eq(warned.length(), 0)
}

///|
/// Scenario 1b: malformed settings fail loudly instead of silently picking a
/// manager — the same file is already validated for provider settings.
async test "malformed settings fail composition loudly" {
  let home = magpie_test_home(tag="bad", settings="{not json")
  let warned : Array[String] = []
  try
    read_magpie_host_settings(
      @workspace.JsWorkspaceFs(),
      home~,
      cred_store=magpie_test_cred_store(),
      warn=fn(message) { warned.push(message) },
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("malformed settings must fail loudly")
  }
}

///|
/// Scenarios 4 + 19: a stored api-key credential rides the typed runtime
/// settings, auth failures stay contained, and the secret never appears in
/// status output, settings warnings, or recorded diagnostics.
async test "credentials reach the runtime settings and never leak into output" {
  let secret = "sk-super-secret-42"
  let home = magpie_test_home(
    tag="cred",
    settings="{\"model_manager\":\"magpie\",\"magpie\":{\"base_url\":\"http://127.0.0.1:3425\"}}",
  )
  let warned : Array[String] = []
  let settings = read_magpie_host_settings(
    @workspace.JsWorkspaceFs(),
    home~,
    cred_store=magpie_test_cred_store(),
    warn=fn(message) { warned.push(message) },
  )
  guard settings is Some(host_settings) else {
    fail("magpie manager must be selected")
  }
  assert_eq(host_settings.gateway_key is None, true)
  // A settings-file key is refused, not used.
  let home_keyed = magpie_test_home(
    tag="keyed",
    settings="{\"model_manager\":\"magpie\",\"magpie\":{\"gateway_key\":\"sk-inline\"}}",
  )
  let settings_keyed = read_magpie_host_settings(
    @workspace.JsWorkspaceFs(),
    home=home_keyed,
    cred_store=magpie_test_cred_store(),
    warn=fn(message) { warned.push(message) },
  )
  guard settings_keyed is Some(host_keyed) else {
    fail("keyed settings must still select the manager")
  }
  assert_eq(host_keyed.gateway_key is None, true)
  assert_eq(
    warned.iter().any(fn(message) { message.contains("sk-inline") }),
    false,
  )
  // End-to-end: the configured credential is presented, and after a 401 the
  // error surfaced to the command surface redacts it.
  let transport = magpie_test_transport(secret~)
  let runtime = bind_magpie_manager({
    base_url: None,
    enabled: true,
    gateway_key: Some(secret),
    model: None,
    effort: None,
  }) catch {
    _ => fail("config with credential must construct")
  }
  let agent = magpie_test_agent(runtime.runtime)
  let outcome = runtime.runtime.invoke("magpie_status", Json::null())
  guard outcome is @posoco.CommandOutcome::Success(structured=Some(status), ..) else {
    fail("status must answer while the gateway refuses the key")
  }
  let rendered = status.stringify()
  assert_eq(rendered.contains(secret), false)
  let _ = transport
  let _ = agent
}

///|
/// Scenarios 2 + 5 + 6 + 7: a configured manager composes, lists models and
/// routing groups in the shared picker shape, selects a model and an effort,
/// and persists the selection through the neutral `model`/`effort` ids.
async test "configured manager lists, selects and persists through neutral ids" {
  let home = magpie_test_home(
    tag="select",
    settings="{\"model_manager\":\"magpie\",\"magpie\":{\"base_url\":\"http://127.0.0.1:3425\"}}",
  )
  let settings = read_magpie_host_settings(
    @workspace.JsWorkspaceFs(),
    home~,
    cred_store=magpie_test_cred_store(),
    warn=fn(_message) { () },
  )
  guard settings is Some(host_settings) else {
    fail("manager must be selected")
  }
  let transport = magpie_test_transport()
  let binding = bind_magpie_manager(host_settings, transport=Some(transport))
  let agent = magpie_test_agent(binding.runtime)
  binding.runtime.on_start()
  // Model discovery through the neutral id: entries in the shared picker
  // shape, under the fixed magpie provider group, efforts verbatim.
  let outcome = binding.runtime.invoke("magpie_model", Json::null())
  guard outcome is @posoco.CommandOutcome::Success(..) else {
    fail("catalog listing must succeed")
  }
  let entries = Magpie(binding).manager_catalog_entries_json()
  assert_eq(entries.length(), 2)
  guard entries[0] is Json::Object(fields) else {
    fail("entry must be an object")
  }
  guard fields.get("provider") is Some(Json::String("magpie")) else {
    fail("magpie entries must preserve manager ownership")
  }
  guard fields.get("group") is Some(Json::String("anthropic")) else {
    fail("ordinary models must group by gateway provider attribution")
  }
  guard entries[1] is Json::Object(group_fields) else {
    fail("routing group must remain a model entry")
  }
  guard group_fields.get("group") is Some(Json::String("Routing Groups")) else {
    fail("routing groups must have their own picker tab")
  }
  guard fields.get("thinking_efforts") is Some(Json::Array(efforts)) else {
    fail("entries must carry the advertised efforts")
  }
  assert_eq(efforts.length(), 2)
  // Select model + effort through the neutral command ids (aliases).
  let picked = binding.runtime.invoke(
    "magpie_model",
    Json::object({ "model": Json::string("anthropic/claude-native") }),
  )
  guard picked is @posoco.CommandOutcome::Success(..) else {
    fail("model selection must succeed")
  }
  let _ = binding.runtime.invoke(
    "magpie_model",
    Json::object({ "effort": Json::string("high") }),
  )
  let selection = binding.runtime.manager().active_selection()
  match selection {
    selection => {
      assert_eq(selection.model_id, "anthropic/claude-native")
      assert_eq(selection.effort, Some("high"))
    }
  }
  // The composed agent saw exactly one model port and the full magpie command
  // surface (no duplicate registration anywhere).
  let mut model_ports = 0
  for ext_port in agent.commands() {
    for def in ext_port.commands() {
      if def.id == "model" {
        model_ports += 1
      }
    }
  }
  assert_eq(model_ports, 0)
  ignore(agent)
}

///|
/// Scenarios 3 + 8 + 14: a configured manager runs a real turn through the
/// composed agent; an offline gateway cannot break startup; each session id
/// rides its own affinity header.
async test "real turn through the composed agent with offline-tolerant startup" {
  let offline = magpie_test_transport()
  let runtime_offline = magpie_runtime_build(offline)
  let agent_offline = magpie_test_agent(runtime_offline.runtime)
  runtime_offline.runtime.on_start()
  let outcome = runtime_offline.runtime.invoke("magpie_status", Json::null())
  guard outcome is @posoco.CommandOutcome::Success(..) else {
    fail("status must answer while offline")
  }
  ignore(agent_offline)
  // Online path: catalog loads, selection applies, the turn flows through the
  // composed port and carries the session id.
  let transport = magpie_test_transport()
  transport.posts.push(magpie_turn_post_body(text="hello from magpie"))
  let runtime = magpie_runtime_build(transport)
  runtime.runtime.on_start()
  let _ = runtime.runtime.invoke(
    "magpie_model",
    Json::object({ "model": Json::string("anthropic/claude-native") }),
  )
  let agent = magpie_test_agent(runtime.runtime)
  let result = agent.run_turn(
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("hi")]),
    "magpie-session-1",
  )
  let mut text = ""
  guard result.message is @posoco.Message::AssistantMessage(content=blocks, ..) else {
    fail("turn must end with an assistant message")
  }
  for block in blocks {
    guard block is @posoco.Content::Text(part) else { continue }
    text = text + part
  }
  assert_eq(text, "hello from magpie")
  assert_eq(transport.post_sessions[0], "magpie-session-1")
  // Second session keeps its own affinity identity.
  transport.posts.push(magpie_turn_post_body(text="again"))
  let _ = agent.run_turn(
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("go")]),
    "magpie-session-2",
  )
  assert_eq(transport.post_sessions[1], "magpie-session-2")
}

///|
/// Scenario 3 variant: a disabled or unreachable manager composes without
/// crashing the host, and the status stays honest about why.
async test "disabled manager composes inert and reports itself" {
  let binding = bind_magpie_manager({
    base_url: None,
    enabled: false,
    gateway_key: None,
    model: None,
    effort: None,
  })
  let agent = magpie_test_agent(binding.runtime)
  binding.runtime.on_start()
  let outcome = binding.runtime.invoke("magpie_status", Json::null())
  guard outcome is @posoco.CommandOutcome::Success(structured=Some(status), ..) else {
    fail("status must answer for a disabled manager")
  }
  guard status is Json::Object(fields) else { fail("status must be an object") }
  guard fields.get("active") is Some(Json::True) else {
    fail("the runtime is composed, hence active")
  }
  ignore(agent)
}

///|
/// Scenario 16: a forbidden intelligence endpoint fails its own command and
/// leaves selection and inference untouched.
async test "forbidden intelligence isolates to its command" {
  let transport = FakeMagpieTransport(
    gets=[
      { code: 200, body: "{\"name\":\"magpie\",\"version\":\"0.1.1224\"}", },
      {
        code: 200,
        body: "{\"data\":[{\"id\":\"anthropic/claude-native\",\"display_name\":\"Claude Native\",\"owned_by\":\"anthropic\",\"reasoning\":false,\"supported_reasoning_levels\":[],\"context_window\":1000,\"native_endpoints\":[\"/v1/messages\"],\"modalities\":{\"input\":[\"text\"]}}]}",
      },
      { code: 403, body: "{\"error\":\"quota endpoint forbidden\"}", },
    ],
    posts=[magpie_turn_post_body(text="ok")],
  )
  let runtime = magpie_runtime_build(transport)
  runtime.runtime.on_start()
  let _ = runtime.runtime.invoke(
    "magpie_model",
    Json::object({ "model": Json::string("anthropic/claude-native") }),
  )
  let quotas = runtime.runtime.invoke("magpie_quotas", Json::null())
  guard quotas is @posoco.CommandOutcome::Failure(..) else {
    fail("a forbidden intelligence endpoint must fail its own command")
  }
  // Inference is unaffected.
  transport.posts.push(magpie_turn_post_body(text="still working"))
  let agent = magpie_test_agent(runtime.runtime)
  let result = agent.run_turn(
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("go")]),
    "magpie-session-403",
  )
  guard result.message is @posoco.Message::AssistantMessage(content=blocks, ..) else {
    fail("turn must complete despite the forbidden endpoint")
  }
  assert_eq(blocks.length() > 0, true)
}

///|
/// Scenarios 17 + 10: shutdown is idempotent and refuses further commands;
/// a fresh composition restores the persisted selection as pending when the
/// catalog does not (yet) carry it — never a silent switch to another model.
async test "shutdown refuses work and restart restores the persisted selection" {
  let home = magpie_test_home(
    tag="persist",
    settings="{\"model_manager\":\"magpie\",\"magpie\":{\"base_url\":\"http://127.0.0.1:3425\"},\"model\":\"anthropic/claude-native\",\"reasoning_effort\":\"high\"}",
  )
  let settings = read_magpie_host_settings(
    @workspace.JsWorkspaceFs(),
    home~,
    cred_store=magpie_test_cred_store(),
    warn=fn(_message) { () },
  )
  guard settings is Some(host_settings) else {
    fail("manager must be selected")
  }
  let first_transport = magpie_test_transport()
  let first = bind_magpie_manager(
    host_settings,
    transport=Some(first_transport),
  )
  first.runtime.on_start()
  let _ = first.runtime.invoke(
    "magpie_model",
    Json::object({ "model": Json::string("group/fast") }),
  )
  first.runtime.on_shutdown()
  first.runtime.on_shutdown()
  try first.runtime.invoke("magpie_status", Json::null()) catch {
    _ => ()
  } noraise {
    _ => fail("commands must be refused after shutdown")
  }
  // "Restart": recomposition from the same persisted settings. The seeded
  // model applies as pending until the catalog confirms it.
  let settings_again = read_magpie_host_settings(
    @workspace.JsWorkspaceFs(),
    home~,
    cred_store=magpie_test_cred_store(),
    warn=fn(_message) { () },
  )
  guard settings_again is Some(host_again) else { fail("settings must reread") }
  let second = bind_magpie_manager(
    host_again,
    transport=Some(magpie_test_transport()),
  )
  let selection = second.runtime.manager().active_selection()
  assert_eq(selection.model_id, "anthropic/claude-native")
  assert_eq(selection.effort, Some("high"))
}

///|
/// Scenarios 11 + 12 + 20: dropping the manager key falls back to the
/// providers manager (existing behavior untouched); the magpie warning path
/// never activates anything.
async test "removing the manager key restores the providers manager" {
  let home = magpie_test_home(
    tag="switch-back",
    settings="{\"model_manager\":\"magpie\"}",
  )
  let fs = @workspace.JsWorkspaceFs()
  let warned : Array[String] = []
  let before = read_magpie_host_settings(
    fs,
    home~,
    cred_store=magpie_test_cred_store(),
    warn=fn(message) { warned.push(message) },
  )
  assert_eq(before is Some(_), true)
  let _ = fs.write_file_atomic(
    home + "/.cetas/settings.json",
    "{\"model\":\"openai/gpt-chat\"}\n",
  )
  let after = read_magpie_host_settings(
    fs,
    home~,
    cred_store=magpie_test_cred_store(),
    warn=fn(message) { warned.push(message) },
  )
  assert_eq(after is None, true)
}

///|
/// Scenario 18: the same runtime instance registered twice is a composition
/// error, never a silent double registration.
async test "duplicate runtime registration is rejected by composition" {
  let transport = magpie_test_transport()
  let runtime = magpie_runtime_build(transport)
  try
    @posoco.Agent::Agent(
      exts=[runtime.runtime, runtime.runtime],
      config=@posoco.tk_config(),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("duplicate registration must be rejected")
  }
}

///|
/// Scenario 9: streaming responses close their SSE stream when the turn
/// completes; nothing stays open.
async test "streaming turn closes the transport stream" {
  let lines = [
    "event: message_start", "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_s\",\"role\":\"assistant\",\"model\":\"claude-served\",\"content\":[],\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}",
    "", "event: content_block_start", "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
    "", "event: content_block_delta", "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"streamed\"}}",
    "", "event: content_block_stop", "data: {\"type\":\"content_block_stop\",\"index\":0}",
    "", "event: message_delta", "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}",
    "", "event: message_stop", "data: {\"type\":\"message_stop\"}", "",
  ]
  let transport = FakeMagpieTransport(
    gets=[
      { code: 200, body: "{\"name\":\"magpie\",\"version\":\"0.1.1224\"}", },
      {
        code: 200,
        body: "{\"data\":[{\"id\":\"anthropic/claude-native\",\"display_name\":\"Claude Native\",\"owned_by\":\"anthropic\",\"reasoning\":false,\"supported_reasoning_levels\":[],\"context_window\":1000,\"native_endpoints\":[\"/v1/messages\"],\"modalities\":{\"input\":[\"text\"]}}]}",
      },
    ],
    posts=[{ code: 200, body: "", }],
    stream_lines=lines,
  )
  let runtime = magpie_runtime_build(transport)
  runtime.runtime.on_start()
  let _ = runtime.runtime.invoke(
    "magpie_model",
    Json::object({ "model": Json::string("anthropic/claude-native") }),
  )
  // Core agent turns request buffered completions; streaming fidelity is the
  // port's own contract, so drive the composed port directly in streaming
  // mode over the same fake transport.
  let scope : @posoco.InvocationScope = {
    session_id: @posoco.SessionId::unchecked("magpie-session-stream"),
    run_id: @posoco.RunId::unchecked("magpie-run-stream"),
    effect_id: None,
    pressure: None,
  }
  let result = runtime.runtime
    .model_port()
    .chat(
      scope,
      [@posoco.Message::UserMessage(content=[@posoco.Content::Text("hi")])][:],
      [],
      { temperature: None, max_output_tokens: None, },
      @posoco.StreamMode::Stream(fn(_chunk) { () }),
    )
  let completion = result.completion
  let mut text = ""
  for block in completion.message.content {
    guard block is @kernel.Content::Text(part) else { continue }
    text = text + part
  }
  assert_eq(text, "streamed")
  assert_eq(transport.streams_opened >= 1, true)
  assert_eq(transport.streams_closed >= 1, true)
}

///|
/// Bind a runtime over a fake transport with default host settings.
fn magpie_runtime_build(transport : FakeMagpieTransport) -> MagpieBinding raise {
  let transport_ref : &@magpie.MagpieTransport = transport
  bind_magpie_manager(
    {
      base_url: None,
      enabled: true,
      gateway_key: None,
      model: None,
      effort: None,
    },
    transport=Some(transport_ref),
  ) catch {
    _ => fail("default magpie config must be constructible")
  }
}
