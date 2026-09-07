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
  prompt_contributors : Array[&@posoco.SystemPromptContributor]
  profile_command : ProfileCommand
}

///|
/// Wraps a context contributor so its text is labeled as the
/// `project_context` section when appended by the Agent's system-prompt hook.
priv struct ProjectContextContributor {
  inner : &@posoco.SystemPromptContributor
}

///|
fn ProjectContextContributor::ProjectContextContributor(
  inner : &@posoco.SystemPromptContributor,
) -> ProjectContextContributor {
  { inner, }
}

///|
impl @posoco.SystemPromptContributor for ProjectContextContributor with fn system_prompt(
  self : ProjectContextContributor,
) -> String {
  let text = self.inner.system_prompt()
  if text == "" {
    ""
  } else {
    "project_context:\n" + text
  }
}

///|
/// Build a Cetas extension.
///
/// - `context_contributor` (e.g. AGENTS.md loader) is registered as a
///   prompt contributor when present.
/// - `tool_contributors` (e.g. tool usage guidance) are appended in the
///   order they are supplied.
/// - Profile command callbacks are host-supplied because profile storage is
///   target-specific; cetas only owns the command surface.
pub fn Cetas::Cetas(
  ui~ : &@posoco.UiPort,
  context_contributor? : &@posoco.SystemPromptContributor? = None,
  tool_contributors? : Array[&@posoco.SystemPromptContributor] = [],
  list_profiles~ : () -> Array[ProfileSpec],
  on_load~ : (String) -> Unit,
  on_save~ : (String) -> Unit,
  on_delete~ : (String) -> Unit,
) -> Cetas {
  let prompt_contributors : Array[&@posoco.SystemPromptContributor] = []
  match context_contributor {
    Some(c) =>
      prompt_contributors.push(
        ProjectContextContributor(c) as &@posoco.SystemPromptContributor,
      )
    None => ()
  }
  for c in tool_contributors {
    prompt_contributors.push(c)
  }
  let profile_command = ProfileCommand(
    ui,
    list_profiles~,
    on_load~,
    on_save~,
    on_delete~,
  )
  { prompt_contributors, profile_command, }
}

///|
pub impl @posoco.Extension for Cetas with fn extension_id(_self) -> String {
  "cetas"
}

///|
pub impl @posoco.Extension for Cetas with fn manifest(self) -> @posoco.ExtensionManifest {
  let m = @posoco.ExtensionManifest::empty(id="cetas")
  {
    ..m,
    prompt_contributors: self.prompt_contributors,
    commands: [self.profile_command],
  }
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
/// time by the gen_platform rule from CETAS_TARGET_OS ("windows"/"unix"),
/// so a unix build never registers the ps1 ext and a windows build never
/// registers the bash ext. "auto" (env unset, or the committed default when
/// the rule does not fire) falls back to runtime detection.
fn shell_platform_is_windows() -> Bool {
  match compiled_target_os() {
    "windows" => true
    "unix" => false
    _ => @ps1.is_windows()
  }
}

///|
/// Default feature set: read/write/edit/glob/grep/bash plus agent skills
/// and (with `ui~`) the interactive ask_question tool; Nowledge Mem joins
/// only when baked in or explicitly enabled (the nmem_target knob).
///
/// The six file/shell tools are context-free constructors; skills needs the
/// host process context (fs/cwd/home) for discovery, so the function takes
/// `ctx~`. Knobs: `ui~` gates ask_question (a headless host omits it — an
/// always-erroring tool would only pollute the model's tool list);
/// `enable_rtk~` registers the RTK shell router, decided at compile time by
/// the flavor_target knob; `enable_nmem~` opts into Nowledge Mem, which
/// degrades silently without the service, and a supplied `nmem_group~`
/// starts its background flusher; `shell_family~` swaps bash for the
/// sandboxed mbtx script tool on unix — models stall without a bash-shaped
/// action surface, so bash is the default and mbtx is opt-in; Windows keeps
/// ps1 either way (`bus~` carries the already-subscribed session event bus
/// mbtx self-reports on); `detect_herdr~` registers the herdr presence
/// reporter when the host runs inside a herdr pane.
///
/// Attention budget: the file tools, the two skill tools, and ask_question
/// are the only tools in the model catalog; every episodic tool (shell,
/// webfetch, nmem, obsidian) defers behind the lazytools gateway, whose
/// tool_list / tool_execute are the sole route to it.
///
/// All six file/shell tools share one `WorkspaceAnchor` built from `ctx.cwd`:
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
  ui? : &@posoco.UiPort? = None,
  enable_nmem? : Bool = compiled_nmem_enabled(),
  enable_rtk? : Bool = compiled_rtk_enabled(),
  shell_family? : String = compiled_shell_family(),
  bus? : @devkit.EventBus? = None,
  nmem_group? : @async.TaskGroup[Unit]? = None,
  detect_herdr? : Bool = true,
  host_help_note? : String? = None,
) -> Array[&@posoco.Extension] raise @posoco.CompositionError {
  let freshness = @devkit.FreshnessGuard::FreshnessGuard()
  let anchor = @devkit.WorkspaceAnchor::WorkspaceAnchor(ctx.cwd)
  let exts : Array[&@posoco.Extension] = [
    @read.ReadTools(freshness~, anchor=Some(anchor)),
    @write.WriteTools(freshness~, anchor=Some(anchor)),
    @edit.EditTools(freshness~, anchor=Some(anchor)),
    @glob.GlobTools(anchor=Some(anchor)),
    @grep.GrepTools(anchor=Some(anchor)),
  ]
  // Episodic tools defer behind the lazytools gateway — including bash:
  // the gateway is the only shell surface the model sees, and both the
  // permission policy (read-only shell pre-approval, per-segment approval
  // scopes) and the rtk router classify gateway calls by the inner tool
  // name via the shared unwrap convention, so deferred bash keeps its
  // gating semantics. Each extension's non-tool ports (hooks, commands,
  // memory, prompt) register through its toolless view.
  // webfetch is a read-only tool (URL fetch, no workspace writes) and
  // keeps its permission read class behind the gateway.
  let episodic : Array[&@posoco.Extension] = [
    @webfetch.WebFetchTools() as &@posoco.Extension,
  ]
  // Shell tool choice per platform — deferred behind the gateway like the
  // other episodic tools. The manuals merge into the one skills extension
  // below so both share the activate_skill tool; a second Skills instance
  // would collide on tool names at composition. The unix side is the
  // shell_family knob: "mbtx" swaps bash for the sandboxed MoonBit script
  // tool (bus-threaded so its exemption self-report reaches the already-
  // subscribed gate); Windows keeps ps1 — the knob never reroutes it.
  if shell_platform_is_windows() {
    episodic.push(
      @ps1.PowerShellTools(anchor=Some(anchor)) as &@posoco.Extension,
    )
  } else if shell_family == "mbtx" {
    episodic.push(
      @mbtx.MbtxTools(anchor=Some(anchor), bus~) as &@posoco.Extension,
    )
  } else {
    episodic.push(@bash.ShellTools(anchor=Some(anchor)) as &@posoco.Extension)
  }
  // RTK shell routing is preference-tied (a local rtk install): the
  // flavor_target knob decides at compile time — public builds never
  // register the hook, so shell tools call the platform shell directly.
  if enable_rtk {
    exts.push(@rtk.RTKHook("rtk") as &@posoco.Extension)
  }
  let builtin_manuals = @forme.builtin_manual_skills()
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
  // With built-ins merged in, the skills extension registers even on machines
  // with no discovered skills: the product manual is always present.
  match
    @skills.Skills::from_catalog(
      ctx.fs,
      catalog=@skills.merge_builtin_skills(discovered, builtin_manuals),
      config=cetas_skills_config(),
    ) {
    Ok(skills) => exts.push(skills as &@posoco.Extension)
    Err(_) => ()
  }
  exts.push(@forme.Forme::Forme(host_note=host_help_note) as &@posoco.Extension)
  match (if detect_herdr { @herdr.HerdrReporter::detect() } else { None }) {
    Some(reporter) => exts.push(reporter as &@posoco.Extension)
    None => ()
  }
  match ui {
    Some(port) =>
      exts.push(@askquestion.AskQuestionTools(port) as &@posoco.Extension)
    None => ()
  }
  if enable_nmem {
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
  // the flavor_target knob decides inclusion at compile time (public builds
  // exclude it entirely — no env check survives). When enabled, the
  // CETAS_OBSIDIAN value still names the vault: "on"/"1"/unset targets the
  // active vault, any other non-"off" value names the vault (first CLI
  // argument vault=<name>). Opting in grants whole-vault read/write;
  // destructive writes (permanent delete, overwrite, heading replace/delete)
  // still consent through the composed UI, and the extension degrades
  // per-call when the CLI or the app is unavailable.
  if compiled_obsidian_enabled() {
    let vault : String? = match @env.get_env_var("CETAS_OBSIDIAN") {
      Some(value) if value != "on" && value != "1" && value != "off" =>
        Some(value)
      _ => None
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
