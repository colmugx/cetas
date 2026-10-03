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
async fn load_cetas_subagent_catalog(
  home~ : String,
  cwd~ : String,
  extra? : Array[@kind.KindSpec] = [],
) -> @kind.KindCatalog noraise {
  // On-disk overlays stay optional product configuration: an IO failure must
  // not disable the builtin delegation surface. Settings-carried kinds, by
  // contrast, are validated upstream (load_cetas_subagent_settings).
  let loaded = @kind.KindCatalog::load(home~, cwd~, extra~) catch {
    _ => @kind.KindCatalog::builtin()
  }
  let entries : Array[@kind.KindSpec] = []
  for name in loaded.names() {
    match loaded.get(name) {
      Some(spec) => {
        let tools : Array[String]? = match spec.tools {
          None => None
          Some(list) => {
            let canonical : Array[String] = []
            for tool in list {
              let name = canonical_cetas_tool_name(tool)
              if !canonical.contains(name) {
                canonical.push(name)
              }
            }
            Some(canonical)
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
/// Yolo widens every child posture the kind left open; a ReadOnly kind is an
/// explicit capability restriction and stays ReadOnly.
fn effective_child_mode(
  parent : @permission.PermissionMode,
  kind : @permission.PermissionMode,
) -> @permission.PermissionMode {
  match parent {
    @permission.Yolo =>
      match kind {
        @permission.ReadOnly => @permission.ReadOnly
        _ => @permission.Yolo
      }
    _ => kind
  }
}

///|
priv struct CetasChildComposer {
  parent_router : @llm.RouterModelPort
  /// Live parent posture, read at each spawn so `/permission` switches
  /// propagate to children composed afterwards.
  parent_mode : () -> @permission.PermissionMode
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
  parent_mode~ : () -> @permission.PermissionMode,
  approval? : &@permission.ApprovalSource? = None,
  ui? : &@posoco.UiPort? = None,
  context_fs~ : &@workspace.WorkspaceFs,
  feature_fs~ : &@workspace.WorkspaceFs,
  cwd~ : String,
  home~ : String,
) -> CetasChildComposer {
  {
    parent_router,
    parent_mode,
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
/// The posture a child composed right now receives: the live parent posture
/// widened through `effective_child_mode`.
fn CetasChildComposer::resolve_child_mode(
  self : CetasChildComposer,
  kind_mode : @permission.PermissionMode,
) -> @permission.PermissionMode {
  effective_child_mode((self.parent_mode)(), kind_mode)
}

///|
fn CetasChildComposer::tool_extensions(
  self : CetasChildComposer,
  names : Array[String],
) -> Array[&@posoco.Extension] raise @subagent.ComposerError {
  build_cetas_tools(
    ctx={ fs: self.feature_fs, cwd: self.cwd, home: self.home, },
    names,
  ) catch {
    error =>
      raise @subagent.ComposerError::Failed(
        "child tool composition failed: " + error.to_string(),
      )
  }
}

///|
async fn CetasChildComposer::skills_extension(
  self : CetasChildComposer,
  requested : Array[String],
) -> &@posoco.Extension? raise @subagent.ComposerError {
  build_cetas_skills(
    ctx={ fs: self.feature_fs, cwd: self.cwd, home: self.home, },
    requested=Some(requested),
  ) catch {
    error =>
      raise @subagent.ComposerError::Failed(
        "child skills composition failed: " + error.to_string(),
      )
  }
}

///|
/// Extract the `subagent` section from settings.json text into the config
/// (default_model/default_effort/limits) plus the settings-carried kinds.
/// Absent section → defaults and no extra kinds. A present-but-invalid
/// section is a hard error, matching the provider-settings precedent:
/// user-authored config must fail loudly instead of silently switching
/// subagents back to inheritance.
fn subagent_settings_from_json(
  text : String,
) -> (@subagent_kit.SubagentConfig, Array[@kind.KindSpec]) raise @posoco.CompositionError {
  let json = @json.parse(text) catch {
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-js.subagent",
        detail=".cetas/settings.json is not valid JSON",
      )
  }
  let section : Json? = match json {
    Json::Object(fields) => fields.get("subagent")
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-js.subagent",
        detail=".cetas/settings.json must be an object",
      )
  }
  let section = match section {
    None => return (@subagent_kit.SubagentConfig::defaults(), [])
    Some(section) => section
  }
  let config = @subagent_kit.parse_subagent_config(section.stringify()) catch {
    @subagent_kit.SubagentConfigError::Invalid(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-js.subagent",
        detail="settings.subagent: \{message}",
      )
    @subagent_kit.SubagentConfigError::Malformed(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-js.subagent",
        detail="settings.subagent: \{message}",
      )
  }
  let kinds : Array[@kind.KindSpec] = match section {
    Json::Object(fields) =>
      match fields.get("kinds") {
        None => []
        Some(Json::Array(items)) => {
          let out : Array[@kind.KindSpec] = []
          for item in items {
            let spec : @kind.KindSpec = @kind.kind_spec_from_json(item) catch {
              @kind.KindError::InvalidKindFile(reason) =>
                raise @posoco.CompositionError::ManifestSchemaError(
                  manifest_id="cetas-js.subagent",
                  detail="settings.subagent.kinds: \{reason}",
                )
              @kind.KindError::DuplicateKind(_) =>
                raise @posoco.CompositionError::ManifestSchemaError(
                  manifest_id="cetas-js.subagent",
                  detail="settings.subagent.kinds: duplicate kind name",
                )
            }
            out.push(spec)
          }
          out
        }
        Some(Json::Null) => []
        Some(_) =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="cetas-js.subagent",
            detail="settings.subagent.kinds must be an array",
          )
      }
    _ => []
  }
  (config, kinds)
}

///|
/// Load the subagent settings from the user's settings.json. Read failures
/// are hard errors for the same reason as the provider settings.
async fn load_cetas_subagent_settings(
  home~ : String,
) -> (@subagent_kit.SubagentConfig, Array[@kind.KindSpec]) raise @posoco.CompositionError {
  let settings_path = home + "/.cetas/settings.json"
  let text = match
    @workspace.read_file_result(@workspace.JsWorkspaceFs(), settings_path) {
    Missing => ""
    Failed(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-js.subagent",
        detail=".cetas/settings.json read failed: " + message,
      )
    Content(text) => text
  }
  subagent_settings_from_json(text)
}

///|
async fn build_cetas_subagents(
  parent_router~ : @llm.RouterModelPort,
  parent_mode~ : () -> @permission.PermissionMode,
  approval? : &@permission.ApprovalSource? = None,
  ui? : &@posoco.UiPort? = None,
  observers? : Array[(@subagent_kit.SubagentEvent) -> Unit] = [],
  context_fs~ : &@workspace.WorkspaceFs,
  feature_fs~ : &@workspace.WorkspaceFs,
  cwd~ : String,
  home~ : String,
) -> &@posoco.Extension raise @posoco.CompositionError {
  let (config, extra_kinds) = load_cetas_subagent_settings(home~)
  let composer = CetasChildComposer::CetasChildComposer(
    parent_router~,
    parent_mode~,
    approval~,
    ui~,
    context_fs~,
    feature_fs~,
    cwd~,
    home~,
  )
  let tools = @subagent.SubagentTools::SubagentTools(
    catalog=load_cetas_subagent_catalog(home~, cwd~, extra=extra_kinds),
    config~,
    composer=composer as &@subagent.ChildComposer,
    parent_slot=parent_router.active_slot_id(),
    parent_effort=parent_router.active_effort(),
    parent_selection=Some(fn() {
      (parent_router.active_slot_id(), parent_router.active_effort())
    }),
    observers~,
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
    self.resolve_child_mode(spec.mode),
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
        Some(skills) => exts.push(skills)
        None => ()
      }
    None => ()
  }

  // None = the kind omitted its tool face: inherit the host default core
  // face (delegation tools are not part of it — depth 1 stays structural).
  let tool_names : Array[String] = match spec.tools {
    Some(names) => names
    None => cetas_tool_names()
  }
  for ext in self.tool_extensions(tool_names) {
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
    config=@cetas_core.default_agent_config(
      system_prompt=Some(spec.system_prompt),
    ),
  ) catch {
    error =>
      raise @subagent.ComposerError::Failed(
        "child agent composition failed: " + error.to_string(),
      )
  }
}
