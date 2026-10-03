///|
/// cetas_core.mbt — Target-agnostic host logic shared by cetas hosts.
///
/// This package MUST NOT import any target-specific IO (no @fs, no @process,
/// no extern "js"). All IO is injected by the caller via trait impls.
///
/// The only product-facing surface is the `Cetas` extension: it bundles
/// cetas identity and system-prompt assembly into one Extension so hosts
/// compose `Agent(exts=[cetas, ...])` without reassembling scattered ports.
pub(all) struct Cetas {
  prompt_contributors : Array[&@posoco.SystemPromptContributor]
}

///|
/// Build a Cetas extension.
///
/// - `context_contributor` (e.g. AGENTS.md loader) is registered directly
///   when present; its own <cetas-context> envelope already identifies it.
/// - `tool_contributors` (e.g. tool usage guidance) are appended in the
///   order they are supplied.
pub fn Cetas::Cetas(
  context_contributor? : &@posoco.SystemPromptContributor? = None,
  tool_contributors? : Array[&@posoco.SystemPromptContributor] = [],
) -> Cetas {
  let prompt_contributors : Array[&@posoco.SystemPromptContributor] = []
  match context_contributor {
    Some(c) => prompt_contributors.push(c)
    None => ()
  }
  for c in tool_contributors {
    prompt_contributors.push(c)
  }
  { prompt_contributors, }
}

///|
pub impl @posoco.Extension for Cetas with fn extension_id(_self) -> String {
  "cetas"
}

///|
pub impl @posoco.Extension for Cetas with fn manifest(self) -> @posoco.ExtensionManifest {
  let m = @posoco.ExtensionManifest::default(id="cetas")
  { ..m, prompt_contributors: self.prompt_contributors, commands: [], }
}

///|
pub extend Cetas with @posoco.Extension::{extension_id, manifest}

///|
/// Run a single user prompt through the agent, return the assistant's
/// concatenated text response.
///
/// Extracts Text blocks from the response message; non-text blocks (Image)
/// are skipped. Multi-block responses are joined with newlines.
///
/// `images~` appends inline image blocks after the prompt text (e.g. an
/// `@path` mention the host resolved to bytes). The prompt text keeps the
/// `@path` mention so provenance stays readable; the bytes ride the content
/// array, which every downstream seam (session store, adapters) already
/// carries.
pub async fn run_prompt(
  agent : @posoco.Agent,
  prompt : String,
  session_id : String,
  images? : Array[@posoco.Content] = [],
) -> String raise @posoco.AgentError {
  let blocks : Array[@posoco.Content] = [@posoco.Content::Text(prompt)]
  for image in images {
    blocks.push(image)
  }
  let user_msg : @posoco.Message = @posoco.Message::UserMessage(content=blocks)
  let result = agent.run_turn(user_msg, session_id)
  assistant_text(result)
}

///|
/// Resume a session's interrupted turn from its persisted transcript and
/// return the final assistant text (same projection as `run_prompt`). The
/// Agent replays a trailing user message as-is or appends the fixed
/// continuation — hosts pass no prompt of their own.
pub async fn run_resume(
  agent : @posoco.Agent,
  session_id : String,
) -> String raise @posoco.AgentError {
  let result = agent.resume_turn(session_id)
  assistant_text(result)
}

///|
/// Text-block projection shared by `run_prompt` and `run_resume`.
fn assistant_text(result : @posoco.TurnResult) -> String {
  let builder = StringBuilder()
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

///|
/// Server-side compaction result projected for hosts (the raw kernel outcome
/// type is not part of the posoco root re-exports).
pub(all) struct CompactRunOutcome {
  final_session_id : String
  mode : String
  messages_after : Int
} derive(Eq)

///|
pub extend CompactRunOutcome with Eq::{not_equal, equal}

///|
/// Server-side compaction for a session through the Agent's manual compact
/// entry: same submit/cancel/commit path as turns, no fabricated user turn.
pub async fn run_compact(
  agent : @posoco.Agent,
  session_id : String,
) -> CompactRunOutcome raise @posoco.AgentError {
  let outcome = agent.compact_session(session_id)
  let mode = match outcome.mode {
    NewThread => "NewThread"
    Replace => "Replace"
    Append => "Append"
  }
  {
    final_session_id: outcome.final_session_id,
    mode,
    messages_after: outcome.messages_after,
  }
}

///|
/// Host-process context for default features that need it. cetas-core is a
/// library: it has no cwd/home and owns no filesystem adapter — hosts inject
/// the Workspace port implementation they run on (JsWorkspaceFs /
/// NativeWorkspaceFs), the same injection pattern as the active-model
/// functions.
pub(all) struct HostContext {
  fs : &@workspace.WorkspaceFs
  cwd : String
  home : String
}

///|
/// The cetas default `AgentConfig`, single-sourced so every host (js, acp,
/// headless, ...) ships the same product tuning: `temperature = Some(0.0)`
/// for deterministic coding turns instead of provider-side defaults
/// (modelports that forbid temperature, e.g. kimi k2.6 thinking, strip it
/// themselves). Host-owned knobs pass through: `max_tool_rounds~ : None` is
/// unbounded.
pub fn default_agent_config(
  max_tool_rounds? : Int? = None,
  system_prompt? : String? = None,
) -> @posoco.AgentConfig {
  @posoco.agent_config(max_tool_rounds~, temperature=Some(0.0), system_prompt~)
}
