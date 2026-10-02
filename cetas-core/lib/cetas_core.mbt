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
/// Cetas product policy for the skills extension, single-sourced here so
/// hosts do not restate it. The activation budget is raised above the
/// portable default so large real-world skills (50k+ chars of instructions)
/// stay loadable.
fn cetas_skills_config() -> @skills.SkillsConfig {
  { ..@skills.SkillsConfig::default(), max_instruction_chars: 65536, }
}

///|
/// Shell-tool platform selection: `compiled_target_os` is baked at compile
/// time by the gen_build_config rule from CETAS_PLATFORM ("windows"/"unix"),
/// so a unix build never registers the ps1 ext and a windows build never
/// registers the bash ext.
fn shell_platform_is_windows() -> Bool {
  compiled_target_os() == "windows"
}

///|
/// Canonical Cetas tool-name normalization. The generic kind catalog names
/// the shell "bash"; Windows Cetas exposes the same capability as "ps1".
/// Keeping this policy in core means hosts never maintain their own tool map.
pub fn canonical_cetas_tool_name(name : String) -> String {
  if shell_platform_is_windows() && name == "bash" {
    "ps1"
  } else {
    name
  }
}

///|
/// Canonical reconstructable tool names — the "default face" a kind inherits
/// when it omits `tools`. Mirrors the `build_cetas_tools` registry (keep the
/// two in sync). Delegation tools (agent, agent_swarm, herdr_delegate, zcode)
/// are extension-provided and deliberately absent: children never spawn.
pub fn cetas_tool_names() -> Array[String] {
  if shell_platform_is_windows() {
    [
      "read", "write", "edit", "glob", "grep", "astgrep", "ps1", "webfetch", "ask_question",
    ]
  } else {
    [
      "read", "write", "edit", "glob", "grep", "astgrep", "bash", "webfetch", "ask_question",
    ]
  }
}

///|
/// Canonical constructor for reconstructable Cetas tools. This is the single
/// place that knows which concrete extension owns a Cetas tool name and how
/// fresh per-agent state (freshness ledger/workspace anchor) is created.
///
/// Hosts and child-agent composers request names; they do not import the
/// concrete read/write/edit/search/shell/webfetch/askquestion packages.
pub fn build_cetas_tools(
  ctx~ : HostContext,
  names : Array[String],
) -> Array[&@posoco.Extension] raise @posoco.CompositionError {
  let anchor = @devkit.WorkspaceAnchor::WorkspaceAnchor(ctx.cwd)
  let freshness = @devkit.FreshnessGuard::FreshnessGuard()
  let exts : Array[&@posoco.Extension] = []
  let seen : Set[String] = Set([])
  for requested in names {
    let name = canonical_cetas_tool_name(requested)
    if seen.contains(name) {
      continue
    }
    seen.add(name)
    match name {
      "read" =>
        exts.push(
          @read.ReadTools(freshness~, anchor=Some(anchor), fs=Some(ctx.fs))
          as &@posoco.Extension,
        )
      "write" =>
        exts.push(
          @write.WriteTools(freshness~, anchor=Some(anchor))
          as &@posoco.Extension,
        )
      "edit" =>
        exts.push(
          @edit.EditTools(freshness~, anchor=Some(anchor)) as &@posoco.Extension,
        )
      "glob" =>
        exts.push(@glob.GlobTools(anchor=Some(anchor)) as &@posoco.Extension)
      "grep" =>
        exts.push(@grep.GrepTools(anchor=Some(anchor)) as &@posoco.Extension)
      "astgrep" =>
        exts.push(
          @astgrep.AstGrepTools(anchor=Some(anchor)) as &@posoco.Extension,
        )
      "bash" =>
        exts.push(@bash.ShellTools(anchor=Some(anchor)) as &@posoco.Extension)
      "ps1" =>
        if shell_platform_is_windows() {
          exts.push(
            @ps1.PowerShellTools(anchor=Some(anchor)) as &@posoco.Extension,
          )
        } else {
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="cetas.tools",
            detail="tool 'ps1' is unavailable in the Unix Cetas build",
          )
        }
      "webfetch" => exts.push(@webfetch.WebFetchTools() as &@posoco.Extension)
      "ask_question" =>
        for ext in build_cetas_tools(ctx~, ["ask_question"]) {
          exts.push(ext)
        }
      _ =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="cetas.tools",
          detail="tool '" +
            requested +
            "' is not in the canonical Cetas tool registry",
        )
    }
  }
  exts
}

///|
/// Canonical skills construction over the same Cetas policy used by parent
/// agents. `requested=None` exposes the full discovered+builtin catalog;
/// `Some(names)` restricts activation to those skills. The returned value is
/// only an Extension so callers do not need a direct dependency on ext-skills.
pub async fn build_cetas_skills(
  ctx~ : HostContext,
  requested? : Array[String]? = None,
) -> &@posoco.Extension? raise @posoco.CompositionError {
  let discovered : @skills.SkillCatalog = match
    @skills.Skills::discover(
      ctx.fs,
      cwd=ctx.cwd,
      home=ctx.home,
      config=cetas_skills_config(),
    ) {
    Some(skills) => skills.catalog()
    None => @skills.SkillCatalog::empty()
  }
  let full = @skills.merge_builtin_skills(
    discovered,
    @forme.builtin_manual_skills(),
  )
  let catalog = match requested {
    None => full
    Some(names) if names.is_empty() => full
    Some(names) => {
      let selected : Array[@skills.SkillDescriptor] = []
      for name in names {
        match full.find(name) {
          Some(skill) => selected.push(skill)
          None =>
            raise @posoco.CompositionError::ManifestSchemaError(
              manifest_id="cetas.skills",
              detail="unknown skill '" +
                name +
                "' (available: " +
                full.names().join(", ") +
                ")",
            )
        }
      }
      @skills.SkillCatalog::{ skills: selected, diagnostics: [], }
    }
  }
  match
    @skills.Skills::from_catalog(ctx.fs, catalog~, config=cetas_skills_config()) {
    Ok(skills) => Some(skills as &@posoco.Extension)
    Err(reason) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas.skills",
        detail="skills composition failed: " + reason,
      )
  }
}

///|
/// Build the extension set selected by the compile recipe.
///
/// The concrete dependency list and constructor registry live in
/// recipe.generated.mbt, produced by scripts/prepare-recipe.py before Moon
/// resolves the package graph. Missing recipe dependencies are intentionally
/// compile errors rather than runtime feature gates.
pub async fn build_default_features(
  ctx~ : HostContext,
  nmem_group? : @async.TaskGroup[Unit]? = None,
  host_help_note? : String? = None,
  obsidian_vault? : String? = None,
) -> Array[&@posoco.Extension] raise @posoco.CompositionError {
  build_compiled_recipe_features(
    ctx~,
    nmem_group~,
    host_help_note~,
    obsidian_vault~,
  )
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
