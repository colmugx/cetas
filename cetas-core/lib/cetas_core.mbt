///|
/// cetas_core.mbt — Target-agnostic host logic shared by cetas-native and cetas-js.
///
/// This package MUST NOT import any target-specific IO (no @fs, no @process,
/// no extern "js"). All IO is injected by the caller via trait impls.

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
      println("  -> \{call.name.to_string()}(\{call.arguments.stringify()})")
    @posoco.TurnEvent::ToolCallResult(call~, result~, is_error~) => {
      let status = if is_error { "x" } else { "ok" }
      println("  [\{status}] \{call.name.to_string()}")
      let brief = match result {
        Success(content~, ..) => content
        ToolReportedError(content~, ..) => content
        RuntimeFailure(message~, ..) => message
        NotExecuted(..) => "not executed"
      }
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

///|
/// Host-level configuration. The model/api_key/tools-specific bits stay in
/// cetas-native / cetas-js because they depend on target-specific ext packages.
pub(all) struct CetasHostConfig {
  cwd : String
  max_tool_rounds : Int
  temperature : Double?
  max_output_tokens : Int?
  model_context_window : Int?
}

///|
pub fn CetasHostConfig::CetasHostConfig(
  cwd : String,
  max_tool_rounds? : Int = 20,
  temperature? : Double? = None,
  max_output_tokens? : Int? = None,
  model_context_window? : Int? = None,
) -> CetasHostConfig {
  { cwd, max_tool_rounds, temperature, max_output_tokens, model_context_window }
}

///|
pub fn build_agent_from_parts(
  model : &@posoco.ModelPort,
  tools : Array[&@posoco.ToolProvider],
  prompt_contributors : Array[&@posoco.SystemPromptContributor],
  feature_pre_model_hooks : Array[&@posoco.PreModelHook],
  commands : Array[&@posoco.CommandPort],
  store : &@posoco.SessionStore,
  observer : &@posoco.Observer,
  ui : &@posoco.UiPort,
  config : CetasHostConfig,
  context_contributor? : &@posoco.SystemPromptContributor? = None,
) -> @posoco.Agent raise @posoco.CompositionError {
  let contributors_with_ids : Array[@posoco.SystemPromptSection] = []
  // Context contributor (AGENTS.md etc.) gets its own section label so the
  // assembled prompt reads "project_context:" above the <cetas-context> blocks.
  match context_contributor {
    Some(c) =>
      contributors_with_ids.push(
        @posoco.SystemPromptSection::SystemPromptSection(
          id="project_context",
          contributor=c,
        ),
      )
    None => ()
  }
  // Tool contributors share the "tool_guidance" label.
  for c in prompt_contributors {
    contributors_with_ids.push(
      @posoco.SystemPromptSection::SystemPromptSection(
        id="tool_guidance",
        contributor=c,
      ),
    )
  }
  let system_prompt = @posoco.SystemPromptHook(
    base_prompt=cetas_base_system_prompt(config.cwd),
    contributors=contributors_with_ids,
  )
  let pre_model_hooks : Array[&@posoco.PreModelHook] = [system_prompt]
  for hook in feature_pre_model_hooks {
    pre_model_hooks.push(hook)
  }
  let agent_config : @posoco.AgentConfig = {
    max_tool_rounds: config.max_tool_rounds,
    temperature: config.temperature,
    max_output_tokens: config.max_output_tokens,
    model_context_window: config.model_context_window,
  }
  @posoco.Agent(
    exts=[
      @posoco.ManifestOnly::ManifestOnly({
        id: "model",
        models: [model],
        tools: [],
        sessions: [],
        observers: [],
        pre_model_hooks: [],
        pre_tool_hooks: [],
        post_event_hooks: [],
        memory: [],
        lifecycle: [],
        commands: [],
        ui: [],
        prompt_contributors: [],
      }),
      @posoco.ManifestOnly::ManifestOnly({
        id: "tools",
        models: [],
        tools,
        sessions: [],
        observers: [],
        pre_model_hooks: [],
        pre_tool_hooks: [],
        post_event_hooks: [],
        memory: [],
        lifecycle: [],
        commands: [],
        ui: [],
        prompt_contributors: [],
      }),
      @posoco.ManifestOnly::ManifestOnly({
        id: "hooks",
        models: [],
        tools: [],
        sessions: [],
        observers: [],
        pre_model_hooks,
        pre_tool_hooks: [],
        post_event_hooks: [],
        memory: [],
        lifecycle: [],
        commands,
        ui: [],
        prompt_contributors: [],
      }),
      @posoco.ManifestOnly::ManifestOnly({
        id: "io",
        models: [],
        tools: [],
        sessions: [store],
        observers: [observer],
        pre_model_hooks: [],
        pre_tool_hooks: [],
        post_event_hooks: [],
        memory: [],
        lifecycle: [],
        commands: [],
        ui: [ui],
        prompt_contributors: [],
      }),
    ],
    config=agent_config,
  )
}

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
  let user_msg : @posoco.Message = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text(prompt),
  ])
  let result = agent.run_turn(user_msg, session_id)
  let builder = StringBuilder::new()
  // Extract Text blocks from the assistant's final message.
  let content_blocks = match result.message {
    AssistantMessage(content~, ..) => content
    _ => []
  }
  for block in content_blocks {
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

// Model/provider adapters and logging remain host-owned.

///|
/// Default tool set: read/write/edit/glob/grep/bash.
///
/// Order matters for diagnostics readability; it does not affect execution.
///
/// Returns only ToolProviders. The tools' own `description` fields carry their
/// usage guidance to the model via the tool schema; no SystemPromptContributor
/// is emitted here.
pub fn build_default_features() -> Array[&@posoco.ToolProvider] {
  let read = @read.ReadTools::ReadTools()
  let write = @write.WriteTools::WriteTools()
  let edit = @edit.EditTools::EditTools()
  let glob = @glob.GlobTools::GlobTools()
  let grep = @grep.GrepTools::GrepTools()
  let bash = @bash.ShellTools::ShellTools()
  [read, write, edit, glob, grep, bash]
}
