///|
/// cetas_core.mbt — Target-agnostic host logic shared by cetas-native and cetas-js.
///
/// This package MUST NOT import any target-specific IO (no @fs, no @process,
/// no extern "js"). All IO is injected by the caller via trait impls.
///
/// Public surface:
///   - InMemorySessionStore: SessionStore impl for dev/test (no persistence)
///   - PrintObserver: Observer impl that prints turn events to stdout
///   - CetasHostConfig: agent-level configuration (max_tool_rounds, etc)
///   - build_agent_from_parts: pure assembly, takes injected model/tools/etc
///   - run_prompt: pure, runs one turn and extracts assistant text

// ============================================================================
// InMemorySessionStore — pure in-process map, no IO.
// ============================================================================

///|
/// In-memory session store. Single-process, no persistence.
/// Both cetas-native (when persistence is disabled) and cetas-js (when
/// persistence is not desired) can use this directly.
pub(all) struct InMemorySessionStore {
  sessions : Map[String, @posoco.Session]
}

///|
pub fn InMemorySessionStore::new() -> InMemorySessionStore {
  { sessions: Map::from_array([]) }
}

///|
pub impl @posoco.SessionStore for InMemorySessionStore with fn load(
  self,
  id : String,
) -> @posoco.Session raise @posoco.SessionError {
  match self.sessions.get(id) {
    Some(s) => s
    None => { messages: [], metadata: Map::from_array([]) }
  }
}

///|
pub impl @posoco.SessionStore for InMemorySessionStore with fn save(
  self,
  id : String,
  session : @posoco.Session,
) -> Unit raise @posoco.SessionError {
  self.sessions[id] = session
}

// ============================================================================
// PrintObserver — uses println only, no other IO.
// ============================================================================

///|
/// Print observer: echoes turn events to stdout for user visibility.
/// Both hosts can use this as a fallback Observer when they don't have a
/// richer UI (cetas-js with pi-tui will provide its own JsTuiObserver instead).
pub(all) struct PrintObserver {}

///|
pub fn PrintObserver::new() -> PrintObserver {
  PrintObserver::{  }
}

///|
pub impl @posoco.Observer for PrintObserver with fn on_event(
  _self,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::ToolCallPending(call) =>
      println("  -> \{call.name}(\{call.arguments.stringify()})")
    @posoco.TurnEvent::ToolCallResult(call~, result~, is_error~) => {
      let status = if is_error { "x" } else { "ok" }
      println("  [\{status}] \{call.name}")
      let brief = result.content
      if brief.length() > 200 {
        println("    " + brief[0:200].to_owned() + "...")
      } else {
        println("    " + brief)
      }
    }
    @posoco.TurnEvent::TurnFailed(msg) => println("  [x] Turn failed: \{msg}")
    _ => ()
  }
}

// ============================================================================
// CetasHostConfig — agent-level configuration.
// ============================================================================

///|
/// Host-level configuration. The model/api_key/tools-specific bits stay in
/// cetas-native / cetas-js because they depend on target-specific ext packages.
pub(all) struct CetasHostConfig {
  cwd : String
  max_tool_rounds : Int
  temperature : Double?
  max_output_tokens : Int?
  tool_choice : @posoco.ToolChoice?
  reasoning_effort : @posoco.ReasoningEffort?
  model_context_window : Int?
}

///|
pub fn CetasHostConfig::CetasHostConfig(
  cwd : String,
  max_tool_rounds? : Int = 20,
  temperature? : Double? = None,
  max_output_tokens? : Int? = None,
  tool_choice? : @posoco.ToolChoice? = None,
  reasoning_effort? : @posoco.ReasoningEffort? = None,
  model_context_window? : Int? = None,
) -> CetasHostConfig {
  {
    cwd,
    max_tool_rounds,
    temperature,
    max_output_tokens,
    tool_choice,
    reasoning_effort,
    model_context_window,
  }
}

// ============================================================================
// build_agent_from_parts — pure assembly.
// ============================================================================

///|
/// Assemble a posoco Agent from pre-built parts. This is the single
/// composition point shared by cetas-native and cetas-js — each host builds
/// its own model/tools/store/observer (target-specific) and hands them here.
///
/// The agent gets NoopCompressor, no hooks, no memory, no lifecycle —
/// hosts that want those can call Agent::new directly instead.
pub fn build_agent_from_parts(
  model : &@posoco.ModelPort,
  tools : Array[&@posoco.ToolProvider],
  prompt_contributors : Array[&@posoco.SystemPromptContributor],
  feature_hooks : Array[&@posoco.PipelineHook],
  store : &@posoco.SessionStore,
  observer : &@posoco.Observer,
  ui : &@posoco.UiPort,
  config : CetasHostConfig,
) -> @posoco.Agent raise @posoco.CompositionError {
  let system_prompt = @posoco.SystemPromptHook::new(
    cetas_base_system_prompt(config.cwd),
    prompt_contributors,
  )
  let hooks : Array[&@posoco.PipelineHook] = [system_prompt]
  for hook in feature_hooks {
    hooks.push(hook)
  }
  let agent_config : @posoco.AgentConfig = {
    max_tool_rounds: config.max_tool_rounds,
    temperature: config.temperature,
    max_output_tokens: config.max_output_tokens,
    tool_choice: config.tool_choice,
    reasoning_effort: config.reasoning_effort,
    model_context_window: config.model_context_window,
  }
  @posoco.Agent::new(
    model,
    tools~,
    hooks~,
    memory=[],
    compressors=[@posoco.NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    ui=Some(ui),
    config=agent_config,
  )
}

// ============================================================================
// run_prompt — pure turn runner.
// ============================================================================

///|
/// Run a single user prompt through the agent, return the assistant's
/// concatenated text response.
///
/// Extracts Text blocks from the response message; non-text blocks (Image)
/// are skipped. Multi-block responses are joined with newlines.
pub async fn run_prompt(
  agent : @posoco.Agent,
  prompt : String,
  session_id : String,
) -> String raise @posoco.AgentError {
  let user_msg : @posoco.Message = {
    role: User,
    content: [@posoco.Content::Text(prompt)],
    tool_calls: [],
    tool_call_id: None,
    name: None,
    reasoning_content: None,
  }
  let result = agent.run_turn(user_msg, session_id)
  let builder = StringBuilder::new()
  for block in result.message.content {
    match block {
      Text(t) => {
        builder.write_string(t)
        builder.write_char('\n')
      }
      _ => ()
    }
  }
  builder.to_string()
}

// ============================================================================
// build_default_* — canonical assembly backed by ext-* packages.
//
// These helpers wire up the same set of extensions on both cetas-native and
// cetas-js so the two hosts behave identically. All listed ext-* packages
// support both native and js targets (posoco-ext-log ships a ConsoleLogger
// in its main package for cross-target use; xlog-backed logging is available
// via the posoco-ext-log/xlog_native subpackage on native only).
// ============================================================================

///|
/// Default tool set: read/write/edit/glob/grep/bash.
///
/// Order matters for diagnostics readability; it does not affect execution.
pub fn build_default_features() -> (
  Array[&@posoco.ToolProvider],
  Array[&@posoco.SystemPromptContributor],
) {
  let read = @read.ReadTools::ReadTools()
  let write = @write.WriteTools::WriteTools()
  let edit = @edit.EditTools::EditTools()
  let glob = @glob.GlobTools::GlobTools()
  let grep = @grep.GrepTools::GrepTools()
  let bash = @bash.ShellTools::ShellTools()
  let tools : Array[&@posoco.ToolProvider] = [
    read, write, edit, glob, grep, bash,
  ]
  let prompts : Array[&@posoco.SystemPromptContributor] = [
    read, write, edit, glob, grep, bash,
  ]
  (tools, prompts)
}

///|
/// Split a possibly-prefixed base URL into a clean origin and a path prefix.
///
/// `@http.Client(uri)` requires that the URI contains no path segment (the
/// guard checks path is "/").  When `DEEPSEEK_BASE_URL` carries a path such as
/// `http://127.0.0.1:8998/v1`, the host address must be separated from the path
/// prefix so the HTTP client receives a clean origin and the path is prepended
/// to every endpoint call.
///
/// Examples:
///   `"http://127.0.0.1:8998/v1"` → `("http://127.0.0.1:8998", "/v1")`
///   `"https://api.deepseek.com"` → `("https://api.deepseek.com", "")`
fn split_base_url(url : String) -> (String, String) {
  match url.find("://") {
    None => (url, "")
    Some(protocol_end) => {
      let after_protocol_start = protocol_end + 3
      let after_protocol = url.sub(start=after_protocol_start)
      match after_protocol.find("/") {
        None => (url, "")
        Some(slash_pos) => {
          let host_end = after_protocol_start + slash_pos
          let clean_base = url.sub(end=host_end).to_owned()
          let prefix = after_protocol.sub(start=slash_pos).to_owned()
          // Strip trailing slash so endpoint_prefix + "/chat/completions"
          // produces "/v1/chat/completions" rather than "/v1//chat/completions".
          let prefix_stripped = match prefix.strip_suffix("/") {
            Some(s) => s.to_owned()
            None => prefix
          }
          (clean_base, prefix_stripped)
        }
      }
    }
  }
}

///|
/// Default model: DeepSeek-backed ModelPort.
///
/// `api_key` is required; `base_url` overrides the default DeepSeek endpoint
/// (use this to point at a local OpenAI-compatible server); `model` picks the
/// model name sent in the request body.
///
/// The `base_url` may carry a path segment (e.g. `http://host:port/v1`); this
/// function splits it into a clean origin + `endpoint_prefix` so the HTTP
/// client receives a path-less URI and the prefix is prepended to API paths.
///
/// Returns a `&@posoco.ModelPort` trait reference so callers do not need to
/// import `colmugx/posoco-ext-deepseek` themselves; the DeepSeek-specific
/// impl stays internal to cetas-core.
pub fn build_default_model(
  api_key : String,
  base_url : String,
  model : String,
) -> &@posoco.ModelPort {
  let (clean_base, prefix) = if base_url.length() > 0 {
    split_base_url(base_url)
  } else {
    ("https://api.deepseek.com", "")
  }
  let cfg = @deepseek.DeepSeekConfig::new(
    api_key,
    model~,
    base_url=clean_base,
    endpoint_prefix=prefix,
  )
  let port = @deepseek.DeepSeekModelPort::new(cfg)
  port
}

///|
/// Default logger: cross-target ConsoleLogger.
///
/// On native, writes formatted single-line text to stdout via `println`.
/// On js (bun), writes the same text via global `console.log`.
/// Hosts that want xlog's structured output on native should construct
/// `@log/xlog_native.XlogLogger` directly instead.
pub fn build_default_logger() -> @log.ConsoleLogger {
  @log.ConsoleLogger::new()
}
