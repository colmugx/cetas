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
    base_prompt=cetas_base_system_prompt(),
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
/// Cetas product policy for the skills extension, single-sourced here so
/// hosts do not restate it. The activation budget is raised above the
/// portable default so large real-world skills (50k+ chars of instructions)
/// stay loadable.
fn cetas_skills_config() -> @skills.SkillsConfig {
  { ..@skills.SkillsConfig::default(), max_instruction_chars: 65536 }
}

///|
/// Default feature set: read/write/edit/glob/grep/bash plus agent skills and
/// (with `ui~`) the interactive ask_question tool.
///
/// The six tools are context-free constructors. Skills needs the host
/// process context (fs/cwd/home) for discovery, so the function takes
/// `ctx~`: startup parses only SKILL.md frontmatter — bodies are discarded
/// and re-read on activation (progressive disclosure). A `None`
/// precondition failure from the skills constructor simply skips
/// registration; environment problems surface as catalog diagnostics, never
/// as construction failure.
///
/// `ui~` supplies the host's interactive UI port for ask_question: cetas-js
/// passes its JsUiPort, cetas-acp passes the ACP bridge (elicitation). A
/// headless host omits it and no ask_question tool is registered at all —
/// an always-erroring tool would only pollute the model's tool list.
///
/// Order matters for diagnostics readability; it does not affect execution.
///
/// The three file tools share one `FreshnessGuard`: a successful `read`
/// records the file's stamp, and `write`/`edit` refuse to modify files that
/// were not read in this session or that changed since (model-visible tool
/// errors, so the model re-reads instead of losing the turn). The guard is
/// passed by value; MoonBit structs are reference-backed, so its map is
/// shared across the three tools.
///
/// The RTKHook sits after the bash tool: it validates shell arguments
/// (`cmd`/`command` must be a string) and rewrites commands through the
/// rtk subprocess once a real rewrite is supplied. With the default
/// rewrite it passes commands through unchanged, so wiring it in early
/// only adds the strict shell-argument validation.
///
/// Returns Extensions (each tool ext already impls Extension). Hosts place
/// the result directly into `Agent(exts=[...])`.
pub async fn build_default_features(
  ctx~ : HostContext,
  ui? : &@posoco.UiPort? = None,
) -> Array[&@posoco.Extension] noraise {
  let freshness = @devkit.FreshnessGuard::FreshnessGuard()
  let exts : Array[&@posoco.Extension] = [
    @read.ReadTools(freshness~),
    @write.WriteTools(freshness~),
    @edit.EditTools(freshness~),
    @glob.GlobTools(),
    @grep.GrepTools(),
    @bash.ShellTools(),
    @rtk.RTKHook::new("rtk", fn(cmd) { @rtk.default_rtk_rewrite("rtk", cmd) }),
  ]
  match
    @skills.Skills::new(
      ctx.fs,
      cwd=ctx.cwd,
      home=ctx.home,
      config=cetas_skills_config(),
    ) {
    Some(skills) => exts.push(skills as &@posoco.Extension)
    None => ()
  }
  match ui {
    Some(port) =>
      exts.push(@askquestion.AskQuestionTools::new(port) as &@posoco.Extension)
    None => ()
  }
  exts
}
