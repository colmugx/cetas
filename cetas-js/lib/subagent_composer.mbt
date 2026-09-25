///|
/// JS-host-owned child composition for posoco-ext-subagent.
///
/// Every child gets fresh model-selection state, permission state, and
/// read-before-modify state. Child transcripts live in an Agent-lifetime
/// in-memory store whose lifetime matches the subagent resume registry.
/// Host-dynamic/decorator tools are intentionally not inherited: a ChildSpec
/// may only name core tools Cetas can reconstruct without sharing parent
/// runtime state.

///|
fn subagent_platform_is_windows() -> Bool {
  @cetas_core.compiled_target_os() == "windows"
}

///|
async fn load_cetas_subagent_catalog(
  home~ : String,
  cwd~ : String,
) -> @kind.KindCatalog noraise {
  // Kind overlays are optional product configuration: an IO failure must not
  // disable the builtin delegation surface.
  let loaded = @kind.KindCatalog::load(home~, cwd~) catch {
    _ => @kind.KindCatalog::builtin()
  }
  if !subagent_platform_is_windows() {
    return loaded
  }

  // The generic kind package names the Unix shell "bash". Cetas' Windows
  // product surface exposes the equivalent shell capability as "ps1", so
  // normalize the host-specific tool spelling at the composition boundary.
  let entries : Array[@kind.KindSpec] = []
  for name in loaded.names() {
    match loaded.get(name) {
      Some(spec) => {
        let tools : Array[String] = []
        for tool in spec.tools {
          if tool == "bash" {
            if !tools.contains("ps1") {
              tools.push("ps1")
            }
          } else if !tools.contains(tool) {
            tools.push(tool)
          }
        }
        entries.push({ ..spec, tools, })
      }
      None => ()
    }
  }
  @kind.KindCatalog::with_entries(entries) catch {
    _ => @kind.KindCatalog::builtin()
  }
}

///|
priv struct CetasChildSessionStore {
  sessions : Map[String, @posoco.Session]
}

///|
fn CetasChildSessionStore::CetasChildSessionStore() -> CetasChildSessionStore {
  { sessions: Map::from_array([]), }
}

///|
fn child_session_snapshot(session : @posoco.Session) -> @posoco.Session {
  { messages: session.messages.copy(), metadata: session.metadata.copy(), }
}

///|
impl @posoco.SessionStore for CetasChildSessionStore with fn load(
  self,
  id : String,
) -> @posoco.Session {
  match self.sessions.get(id) {
    Some(session) => child_session_snapshot(session)
    None => { messages: [], metadata: Map::from_array([]), }
  }
}

///|
impl @posoco.SessionStore for CetasChildSessionStore with fn save(
  self,
  id : String,
  session : @posoco.Session,
) -> Unit {
  self.sessions[id] = child_session_snapshot(session)
}

///|
impl @posoco.SessionStore for CetasChildSessionStore with fn append_messages(
  self,
  id : String,
  _from_index : Int,
  messages : ArrayView[@posoco.Message],
) -> Unit {
  let session = match self.sessions.get(id) {
    Some(value) => child_session_snapshot(value)
    None => { messages: [], metadata: Map::from_array([]), }
  }
  let merged = session.messages.copy()
  for message in messages {
    merged.push(message)
  }
  self.sessions[id] = { messages: merged, metadata: session.metadata, }
}

///|
impl @posoco.SessionStore for CetasChildSessionStore with fn truncate(
  self,
  id : String,
  from_index : Int,
) -> Unit {
  let session = match self.sessions.get(id) {
    Some(value) => child_session_snapshot(value)
    None => { messages: [], metadata: Map::from_array([]), }
  }
  let len = session.messages.length()
  let keep = if from_index < 0 {
    0
  } else if from_index > len {
    len
  } else {
    from_index
  }
  self.sessions[id] = {
    messages: session.messages[:keep].to_owned(),
    metadata: session.metadata,
  }
}

///|
/// Child transcript state is intentionally memory-only. The subagent resume
/// registry is also Agent-lifetime state, so persisting transcripts beyond the
/// registry would make a fresh process accidentally reuse stale `subagent-1`
/// data while being unable to resume that old child deliberately.
priv struct CetasChildIo {
  store : CetasChildSessionStore
  observers : Array[&@posoco.Observer]
}

///|
impl @posoco.Extension for CetasChildIo with fn extension_id(
  _self : CetasChildIo,
) -> String {
  "cetas_child_io"
}

///|
impl @posoco.Extension for CetasChildIo with fn manifest(self : CetasChildIo) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="cetas_child_io",
    sessions=[self.store as &@posoco.SessionStore],
    observers=self.observers,
  )
}

///|
priv struct CetasChildComposer {
  parent_router : @llm.RouterModelPort
  child_store : CetasChildSessionStore
  approval : &@permission.ApprovalSource?
  ui : &@posoco.UiPort?
  context_fs : &@workspace.WorkspaceFs
  feature_fs : &@workspace.WorkspaceFs
  cwd : String
  home : String
}

///|
fn CetasChildComposer::CetasChildComposer(
  parent_router~ : @llm.RouterModelPort,
  approval? : &@permission.ApprovalSource? = None,
  ui? : &@posoco.UiPort? = None,
  context_fs~ : &@workspace.WorkspaceFs,
  feature_fs~ : &@workspace.WorkspaceFs,
  cwd~ : String,
  home~ : String,
) -> CetasChildComposer {
  {
    parent_router,
    child_store: CetasChildSessionStore::CetasChildSessionStore(),
    approval,
    ui,
    context_fs,
    feature_fs,
    cwd,
    home,
  }
}

///|
fn CetasChildComposer::tool_extensions(
  self : CetasChildComposer,
  names : Array[String],
) -> Array[&@posoco.Extension] raise @subagent.ComposerError {
  let anchor = @devkit.WorkspaceAnchor::WorkspaceAnchor(self.cwd)
  let freshness = @devkit.FreshnessGuard::FreshnessGuard()
  let exts : Array[&@posoco.Extension] = []
  let seen : Set[String] = Set([])
  for name in names {
    if seen.contains(name) {
      continue
    }
    seen.add(name)
    match name {
      "read" =>
        exts.push(
          @read.ReadTools(
            freshness~,
            anchor=Some(anchor),
            fs=Some(self.feature_fs),
          )
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
        if subagent_platform_is_windows() {
          raise @subagent.ComposerError::Failed(
            "child tool 'bash' is unavailable in the Windows Cetas build",
          )
        } else {
          exts.push(@bash.ShellTools(anchor=Some(anchor)) as &@posoco.Extension)
        }
      "ps1" =>
        if subagent_platform_is_windows() {
          exts.push(
            @ps1.PowerShellTools(anchor=Some(anchor)) as &@posoco.Extension,
          )
        } else {
          raise @subagent.ComposerError::Failed(
            "child tool 'ps1' is unavailable in the Unix Cetas build",
          )
        }
      "webfetch" => exts.push(@webfetch.WebFetchTools() as &@posoco.Extension)
      "ask_question" =>
        exts.push(@askquestion.AskQuestionTools() as &@posoco.Extension)
      other =>
        raise @subagent.ComposerError::Failed(
          "child tool '" +
          other +
          "' is not a reconstructable Cetas core tool; dynamic/decorator tools are not inherited by subagents",
        )
    }
  }
  exts
}

///|
async fn CetasChildComposer::skills_extension(
  self : CetasChildComposer,
  requested : Array[String],
) -> @skills.Skills? raise @subagent.ComposerError {
  let discovered : @skills.SkillCatalog = match
    @skills.Skills::discover(
      self.feature_fs,
      cwd=self.cwd,
      home=self.home,
      config=@cetas_core.cetas_skills_config(),
    ) {
    Some(skills) => skills.catalog()
    None => @skills.SkillCatalog::empty()
  }
  let full = @skills.merge_builtin_skills(
    discovered,
    @forme.builtin_manual_skills(),
  )
  let catalog = if requested.is_empty() {
    full
  } else {
    let selected : Array[@skills.SkillDescriptor] = []
    for name in requested {
      match full.find(name) {
        Some(skill) => selected.push(skill)
        None =>
          raise @subagent.ComposerError::Failed(
            "unknown child skill '" +
            name +
            "' (available: " +
            full.names().join(", ") +
            ")",
          )
      }
    }
    @skills.SkillCatalog::{ skills: selected, diagnostics: [], }
  }
  match
    @skills.Skills::from_catalog(
      self.feature_fs,
      catalog~,
      config=@cetas_core.cetas_skills_config(),
    ) {
    Ok(skills) => Some(skills)
    Err(reason) =>
      raise @subagent.ComposerError::Failed(
        "child skills composition failed: " + reason,
      )
  }
}

///|
async fn build_cetas_subagents(
  parent_router~ : @llm.RouterModelPort,
  approval? : &@permission.ApprovalSource? = None,
  ui? : &@posoco.UiPort? = None,
  context_fs~ : &@workspace.WorkspaceFs,
  feature_fs~ : &@workspace.WorkspaceFs,
  cwd~ : String,
  home~ : String,
) -> &@posoco.Extension noraise {
  let composer = CetasChildComposer::CetasChildComposer(
    parent_router~,
    approval~,
    ui~,
    context_fs~,
    feature_fs~,
    cwd~,
    home~,
  )
  let tools = @subagent.SubagentTools::SubagentTools(
    catalog=load_cetas_subagent_catalog(home~, cwd~),
    config=@subagent_kit.SubagentConfig::defaults(),
    composer=composer as &@subagent.ChildComposer,
    parent_slot=parent_router.active_slot_id(),
    parent_effort=parent_router.active_effort(),
    parent_selection=Some(fn() {
      (parent_router.active_slot_id(), parent_router.active_effort())
    }),
  )
  tools as &@posoco.Extension
}

///|
impl @subagent.ChildComposer for CetasChildComposer with fn compose(
  self : CetasChildComposer,
  spec : @subagent.ChildSpec,
) -> @posoco.Agent raise @subagent.ComposerError {
  // New router value per child: provider ModelPorts may be shared, but mutable
  // active slot/effort selection never is.
  let router = @llm.RouterModelPort(
    slots=self.parent_router.list_slots(),
    default_slot_id=spec.slot,
  ) catch {
    error =>
      raise @subagent.ComposerError::Failed(
        "child model selection failed: " + error.to_string(),
      )
  }
  match spec.effort {
    Some(effort) =>
      router.select_effort(spec.slot, effort) catch {
        error =>
          raise @subagent.ComposerError::Failed(
            "child effort selection failed: " + error.to_string(),
          )
      }
    None => ()
  }

  let permission = @permission.PermissionPolicy(
    spec.mode,
    approval=self.approval,
    workspace=Some(@devkit.WorkspaceAnchor::WorkspaceAnchor(self.cwd)),
  )
  let exts : Array[&@posoco.Extension] = [
    router as &@posoco.Extension,
    permission as &@posoco.Extension,
    CetasChildIo::{ store: self.child_store, observers: spec.observers, }
    as &@posoco.Extension,
  ]

  if spec.context_files {
    let loader = @context.ContextLoader(self.context_fs, home=self.home)
    let bundle = loader.load(self.cwd) catch {
      _ => @context.ContextBundle::empty()
    }
    let contributor = @context.ContextPromptContributor(bundle~, ns="cetas")
    exts.push(
      @cetas_core.Cetas::Cetas(
        context_contributor=Some(
          contributor as &@posoco.SystemPromptContributor,
        ),
      )
      as &@posoco.Extension,
    )
  }

  match spec.skills {
    Some(requested) =>
      match self.skills_extension(requested) {
        Some(skills) => exts.push(skills as &@posoco.Extension)
        None => ()
      }
    None => ()
  }

  for ext in self.tool_extensions(spec.tools) {
    exts.push(ext)
  }
  match self.ui {
    Some(ui) =>
      exts.push(
        @cetas_core.UiPortExtension::UiPortExtension(id="cetas_child_ui", ui~)
        as &@posoco.Extension,
      )
    None => ()
  }

  @posoco.Agent(
    exts~,
    config=@cetas_core.default_agent_config(system_prompt=Some(spec.system_prompt)),
  ) catch {
    error =>
      raise @subagent.ComposerError::Failed(
        "child agent composition failed: " + error.to_string(),
      )
  }
}
