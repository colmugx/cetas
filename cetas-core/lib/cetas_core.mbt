///|
/// cetas_core.mbt — Target-agnostic host logic shared by cetas hosts.
///
/// This package MUST NOT import any target-specific IO (no @fs, no @process,
/// no extern "js"). All IO is injected by the caller via trait impls.
///
/// The only product-facing surface is the `Cetas` extension: it bundles
/// cetas identity, system-prompt assembly, and the `/profile` command into
/// one Extension so hosts compose `Agent(exts=[cetas, ...])` without
/// reassembling scattered ports.
pub(all) struct Cetas {
  system_prompt_hook : @posoco.SystemPromptHook
  profile_command : ProfileCommand
}

///|
/// Build a Cetas extension.
///
/// - `context_contributor` (e.g. AGENTS.md loader) becomes the
///   `project_context` prompt section.
/// - `tool_contributors` (e.g. tool usage guidance) share the
///   `tool_guidance` prompt section.
/// - Profile command callbacks are host-supplied because profile storage is
///   target-specific; cetas only owns the command surface.
pub fn Cetas::Cetas(
  cwd~ : String,
  ui~ : &@posoco.UiPort,
  context_contributor? : &@posoco.SystemPromptContributor? = None,
  tool_contributors? : Array[&@posoco.SystemPromptContributor] = [],
  list_profiles~ : () -> Array[ProfileSpec],
  on_load~ : (String) -> Unit,
  on_save~ : (String) -> Unit,
  on_delete~ : (String) -> Unit,
) -> Cetas raise @posoco.CompositionError {
  let sections : Array[@posoco.SystemPromptSection] = []
  match context_contributor {
    Some(c) =>
      sections.push(
        @posoco.SystemPromptSection::SystemPromptSection(
          id="project_context",
          contributor=c,
        ),
      )
    None => ()
  }
  for c in tool_contributors {
    sections.push(
      @posoco.SystemPromptSection::SystemPromptSection(
        id="tool_guidance",
        contributor=c,
      ),
    )
  }
  let system_prompt_hook = @posoco.SystemPromptHook::SystemPromptHook(
    base_prompt=cetas_base_system_prompt(cwd),
    contributors=sections,
  )
  let profile_command = ProfileCommand::new(
    ui,
    list_profiles~,
    on_load~,
    on_save~,
    on_delete~,
  )
  { system_prompt_hook, profile_command }
}

///|
pub impl @posoco.Extension for Cetas with fn extension_id(_self) -> String {
  "cetas"
}

///|
pub impl @posoco.Extension for Cetas with fn manifest(self) -> @posoco.ExtensionManifest {
  let m = @posoco.ExtensionManifest::empty(id="cetas")
  { ..m, hooks: [self.system_prompt_hook], commands: [self.profile_command] }
}

///|
pub extend Cetas with @posoco.Extension::{extension_id, manifest}

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

///|
/// Default tool set: read/write/edit/glob/grep/bash.
///
/// Order matters for diagnostics readability; it does not affect execution.
///
/// Returns Extensions (each tool ext already impls Extension). Hosts place
/// the result directly into `Agent(exts=[...])`.
pub fn build_default_features() -> Array[&@posoco.Extension] {
  [
    @read.ReadTools::ReadTools(),
    @write.WriteTools::WriteTools(),
    @edit.EditTools::EditTools(),
    @glob.GlobTools::GlobTools(),
    @grep.GrepTools::GrepTools(),
    @bash.ShellTools::ShellTools(),
  ]
}
