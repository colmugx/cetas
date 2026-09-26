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
/// Default feature set: read/write/edit/glob/grep/astgrep/bash plus agent
/// skills and (with `ui~`) the interactive ask_question tool. The flavor-gated
/// extensions (Nowledge Mem, Obsidian, RTK) register only where the flavor
/// table baked at compile time enables them — no runtime knob exists.
///
/// The seven file/search/shell tools are context-free constructors; skills
/// needs the host process context (fs/cwd/home) for discovery, so the
/// function takes `ctx~`. Knobs: `ui~` gates ask_question (a headless host
/// omits it — an always-erroring tool would only pollute the model's tool
/// list); `nmem_group~` starts nmem's background flusher; `obsidian_vault~`
/// injects the obsidian vault name so composition can avoid process env
/// (`None` keeps the CETAS_OBSIDIAN contract); the unix shell is bash and
/// Windows keeps ps1.
///
/// Attention budget: the file tools, astgrep, bash, the two skill tools,
/// and ask_question are the only tools in the model catalog; every other
/// episodic tool (webfetch, nmem, obsidian, Windows ps1) defers behind the
/// lazytools gateway, whose tool_list / tool_execute are the sole route to
/// it.
///
/// All seven direct tools share one `WorkspaceAnchor` built from `ctx.cwd`:
/// relative paths in tool calls resolve against the launch directory instead
/// of the host process's inherited cwd. The absolute root exists only on the
/// host side — it never appears in model-visible prompts or tool results,
/// which speak workspace-relative paths only.
///
/// Returns Extensions (each tool ext already impls Extension); hosts place
/// the result directly into `Agent(exts=[...])`. Per-knob rationale lives
/// in the inline comments at each registration site and in the contributing
/// extension packages.
pub async fn build_default_features(
  ctx~ : HostContext,
  nmem_group? : @async.TaskGroup[Unit]? = None,
  host_help_note? : String? = None,
  obsidian_vault? : String? = None,
) -> Array[&@posoco.Extension] raise @posoco.CompositionError {
  let exts = build_cetas_tools(ctx~, [
    "read", "write", "edit", "glob", "grep", "astgrep",
  ])
  // Episodic tools defer behind the lazytools gateway. Each extension's
  // non-tool ports (hooks, commands, memory, prompt) register through its
  // toolless view.
  // webfetch is a read-only tool (URL fetch, no workspace writes) and
  // keeps its permission read class behind the gateway.
  let episodic = build_cetas_tools(ctx~, ["webfetch"])
  // Shell tool choice per platform. Unix's bash is a direct catalog tool —
  // a coding turn shells out constantly, so the gateway hop only added
  // latency; permission and rtk classify by the tool name (the shared
  // unwrap convention passes direct calls through unchanged), so bash
  // keeps its gating semantics without the gateway. Windows keeps ps1
  // deferred like the other episodic tools. The manuals merge into the one
  // skills extension below so both share the activate_skill tool; a second
  // Skills instance would collide on tool names at composition.
  let shell = build_cetas_tools(ctx~, ["bash"])
  if shell_platform_is_windows() {
    for ext in shell {
      episodic.push(ext)
    }
  } else {
    for ext in shell {
      exts.push(ext)
    }
  }

  // With built-ins merged in, the skills extension registers even on machines
  // with no discovered skills: the product manual is always present.
  let skills = build_cetas_skills(ctx~) catch { _ => None }
  match skills {
    Some(skills) => exts.push(skills)
    None => ()
  }
  exts.push(@forme.Forme::Forme(host_note=host_help_note) as &@posoco.Extension)
  // ask_question self-wires from the CompositionView (requires Capability::Ui);
  // registering it unconditionally keeps the tool visible even in UI-less
  // compositions, where each ask reports "Interactive UI is unavailable".
  exts.push(@askquestion.AskQuestionTools() as &@posoco.Extension)
  if compiled_nmem_enabled() {
    let nmem = @nmem.NowledgeMem(
      source_app="cetas",
      transport=@nmem.HttpNmemTransport::HttpNmemTransport()
        as &@nmem.NmemTransport,
      mcp=@nmem.LazyNmemMcp::LazyNmemMcp() as &@nmem.NmemMcp,
      platform=@nmem.PlatformFs::PlatformFs() as &@nmem.NmemPlatform,
    )
    match nmem_group {
      Some(group) => nmem.attach(group)
      None => ()
    }
    episodic.push(nmem as &@posoco.Extension)
  }
  // Handoff: the `/handoff` command over the extension's own default store
  // (native @fs / node:fs behind the HandoffStore seam — this package itself
  // still does no IO). The workspace probe reports only the project root:
  // cetas owns no VCS facts today, so branch/HEAD stay unspecified until a
  // host pushes them. No work source is registered yet, so `create` needs
  // structured command arguments for its continuation anchors (objective,
  // current_work, next_action); `inspect` works unconditionally.
  exts.push(
    @handoff.Handoff(
      cwd=ctx.cwd,
      store=@handoff.DefaultHandoffStore() as &@handoff.HandoffStore,
      probe=@handoff.HandoffWorkspaceState(ctx.cwd)
        as &@handoff.HandoffWorkspaceProbe,
      work_sources=[],
    )
    as &@posoco.Extension,
  )
  // Obsidian vault tools via the official Obsidian CLI. Preference-tied:
  // the flavor table bakes inclusion at compile time (public builds exclude
  // it entirely). When enabled, the vault name comes from `obsidian_vault~`
  // when given, else the CETAS_OBSIDIAN env contract applies: "on"/"1"/unset
  // targets the active vault, any other non-"off" value names the vault
  // (first CLI argument vault=<name>). Opting in grants whole-vault
  // read/write; destructive writes (permanent delete, overwrite, heading
  // replace/delete) still consent through the composed UI, and the extension
  // degrades per-call when the CLI or the app is unavailable.
  if compiled_obsidian_enabled() {
    let vault : String? = match obsidian_vault {
      Some(name) => Some(name)
      None =>
        match @env.get_env_var("CETAS_OBSIDIAN") {
          Some(value) if value != "on" && value != "1" && value != "off" =>
            Some(value)
          _ => None
        }
    }
    episodic.push(
      @obsidian.ObsidianTools::new(
        config=@obsidian.ObsidianConfig::ObsidianConfig(vault~, read_only=false),
      )
      as &@posoco.Extension,
    )
  }
  // Assemble the gateway last: deferred providers are indexed here, the
  // toolless views take their originals' places, and only the gateway's
  // tool_list / tool_execute reach the model catalog.
  match @lazytools.LazyTools::defer_extensions(exts=episodic) {
    Ok((gateway, views)) => {
      for view in views {
        exts.push(view)
      }
      exts.push(gateway as &@posoco.Extension)
    }
    Err(message) =>
      raise @posoco.CompositionError::ToolCollision(
        "deferred tool name collision",
        message,
        manifests=["cetas-core.default_features"],
      )
  }
  exts
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
