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
  extra~ : Array[@kind.KindSpec] = [],
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
/// Child transcript state is memory-only by default. A ticket runtime can
/// inject a durable store so one ticket keeps its session across host restarts.
priv struct CetasChildSessionStore {
  sessions : Map[String, @posoco.Session]
  durable : @fs_session.JsonlSessionStore?
}

///|
fn CetasChildSessionStore::CetasChildSessionStore() -> CetasChildSessionStore {
  { sessions: Map::from_array([]), durable: None, }
}

///|
fn CetasChildSessionStore::with_root(root : String) -> CetasChildSessionStore {
  {
    sessions: Map::from_array([]),
    durable: Some(@fs_session.JsonlSessionStore(root)),
  }
}

///|
async fn CetasChildSessionStore::clear_session(
  self : CetasChildSessionStore,
  id : String,
) -> Unit raise @posoco.SessionError {
  self.sessions.remove(id)
  match self.durable {
    Some(store) => {
      let session = store.load(id)
      store.save(id, { messages: [], metadata: session.metadata, })
    }
    None => ()
  }
}

///|
fn child_session_snapshot(session : @posoco.Session) -> @posoco.Session {
  { messages: session.messages.copy(), metadata: session.metadata.copy(), }
}

///|
extend CetasChildSessionStore with @posoco.SessionStore::{load, save}

///|
impl @posoco.SessionStore for CetasChildSessionStore with fn load(
  self,
  id : String,
) -> @posoco.Session raise @posoco.SessionError {
  match self.durable {
    Some(store) => store.load(id)
    None =>
      match self.sessions.get(id) {
        Some(session) => child_session_snapshot(session)
        None => { messages: [], metadata: Map::from_array([]), }
      }
  }
}

///|
impl @posoco.SessionStore for CetasChildSessionStore with fn save(
  self,
  id : String,
  session : @posoco.Session,
) -> Unit raise @posoco.SessionError {
  match self.durable {
    Some(store) => store.save(id, session)
    None => self.sessions[id] = child_session_snapshot(session)
  }
}

///|
impl @posoco.SessionStore for CetasChildSessionStore with fn append_messages(
  self,
  id : String,
  from_index : Int32,
  messages : ArrayView[@posoco.Message],
) -> Unit raise @posoco.SessionError {
  match self.durable {
    Some(store) => store.append_messages(id, from_index, messages)
    None => {
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
  }
}

///|
impl @posoco.SessionStore for CetasChildSessionStore with fn truncate(
  self,
  id : String,
  from_index : Int32,
) -> Unit raise @posoco.SessionError {
  match self.durable {
    Some(store) => {
      let session = store.load(id)
      let len = session.messages.length()
      let keep = if from_index < 0 {
        0
      } else if from_index > len {
        len
      } else {
        from_index
      }
      store.save(id, {
        messages: session.messages[:keep].to_owned(),
        metadata: session.metadata,
      })
    }
    None => {
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
  }
}

///|
/// Child transcript state is memory-only unless the ticket runtime injects a
/// durable store. The generic subagent resume registry remains Agent-lifetime,
/// so a fresh process does not accidentally reuse stale `subagent-1` data.
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
  parent_manager : ModelManagerFace
  /// Live parent posture, read at each spawn so `/permission` switches
  /// propagate to children composed afterwards.
  parent_mode : () -> @permission.PermissionMode
  child_store : CetasChildSessionStore
  approval : &@permission.ApprovalSource?
  ui : &@posoco.UiPort?
  /// Parent question channel: children whose face includes ask_question
  /// get an `ask_question_child` tool answered by the parent agent.
  question : @subagent.ParentQuestionChannel?
  /// Host-owned human question endpoint (Board tickets). Takes precedence
  /// over `question` when present, so the answerer is the Board drawer
  /// rather than the parent agent.
  question_endpoint : &@askquestion.QuestionEndpoint?
  /// Host-owned worker reporting endpoint (Board tickets). When present the
  /// child gets the `report_progress` / `submit_work_report` face; when absent
  /// it gets neither, because a non-ticket child has no ticket to report on.
  reporting : &TicketReportEndpoint?
  context_fs : &@workspace.WorkspaceFs
  feature_fs : &@workspace.WorkspaceFs
  cwd : String
  home : String
  /// Host-owned serving group: child background shells join the same
  /// scope the parent runtime lives in.
  host_group : @async.TaskGroup[Unit]?
}

///|
fn CetasChildComposer::CetasChildComposer(
  parent_manager~ : ModelManagerFace,
  parent_mode~ : () -> @permission.PermissionMode,
  child_store~ : CetasChildSessionStore? = None,
  approval~ : &@permission.ApprovalSource? = None,
  ui~ : &@posoco.UiPort? = None,
  question~ : @subagent.ParentQuestionChannel? = None,
  question_endpoint~ : &@askquestion.QuestionEndpoint? = None,
  reporting~ : &TicketReportEndpoint? = None,
  context_fs~ : &@workspace.WorkspaceFs,
  feature_fs~ : &@workspace.WorkspaceFs,
  cwd~ : String,
  home~ : String,
  host_group~ : @async.TaskGroup[Unit]? = None,
) -> CetasChildComposer {
  {
    parent_manager,
    parent_mode,
    child_store: match child_store {
      Some(store) => store
      None => CetasChildSessionStore::CetasChildSessionStore()
    },
    approval,
    ui,
    question,
    question_endpoint,
    reporting,
    context_fs,
    feature_fs,
    cwd,
    home,
    host_group,
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
  question~ : &@askquestion.QuestionEndpoint? = None,
) -> Array[&@posoco.Extension] raise @subagent.ComposerError {
  build_cetas_tools(
    ctx={ fs: self.feature_fs, cwd: self.cwd, home: self.home, },
    names,
    question~,
    host_group=self.host_group,
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
    manuals=@forme.Forme::Forme().builtin_manual_skills(),
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
  let json = @cetas_core.parse_settings_json(
    text,
    manifest_id="cetas-js.subagent",
  )
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
    Missing => return (@subagent_kit.SubagentConfig::defaults(), [])
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
  parent_manager~ : ModelManagerFace,
  parent_mode~ : () -> @permission.PermissionMode,
  approval~ : &@permission.ApprovalSource? = None,
  ui~ : &@posoco.UiPort? = None,
  observers~ : Array[(@subagent_kit.SubagentEvent) -> Unit] = [],
  context_fs~ : &@workspace.WorkspaceFs,
  feature_fs~ : &@workspace.WorkspaceFs,
  cwd~ : String,
  home~ : String,
  host_group~ : @async.TaskGroup[Unit]? = None,
) -> &@posoco.Extension raise @posoco.CompositionError {
  let (config, extra_kinds) = load_cetas_subagent_settings(home~)
  // One broker serves both sides of the question round trip: the parent's
  // SubagentTools (answer tool, race, injection) and every child's
  // ask_question_child face through the channel view.
  let broker = @subagent.QuestionBroker::QuestionBroker(
    answer_timeout_ms=config.limits.answer_timeout_ms,
  )
  let composer = CetasChildComposer::CetasChildComposer(
    parent_manager~,
    parent_mode~,
    approval~,
    ui~,
    question=Some(broker.channel()),
    context_fs~,
    feature_fs~,
    cwd~,
    home~,
    host_group~,
  )
  let tools = @subagent.SubagentTools::SubagentTools(
    catalog=load_cetas_subagent_catalog(home~, cwd~, extra=extra_kinds),
    config~,
    composer=composer as &@subagent.ChildComposer,
    parent_slot=parent_manager.manager_active_model_id(),
    parent_effort=parent_manager.manager_active_effort(),
    parent_selection=Some(fn() {
      (
        parent_manager.manager_active_model_id(),
        parent_manager.manager_active_effort(),
      )
    }),
    observers~,
    question=Some(broker),
    // Wakeup-port §10 policy: this host integrated the operation lifecycle
    // (operation_settled projection, structured Busy retention), so a
    // background receipt requests one ordinary turn instead of waiting for
    // lazy delivery. Children never compose subagent tools (depth 1), so
    // this opt-in belongs to the host's parent agent only.
    auto_wakeup=true,
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
  let child_model = self.parent_manager.manager_subagent_extension(
    spec_slot=spec.slot,
    spec_effort=spec.effort,
  )

  let permission = @permission.PermissionPolicy(
    self.resolve_child_mode(spec.mode),
    approval=self.approval,
    workspace=Some(@devkit.WorkspaceAnchor::WorkspaceAnchor(self.cwd)),
  )
  let exts : Array[&@posoco.Extension] = [
    child_model,
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
  // Interactive children (face includes ask_question, default face does)
  // get the parent-bound ask face instead of the human one.
  let question : &@askquestion.QuestionEndpoint? = match
    self.question_endpoint {
    Some(endpoint) => Some(endpoint)
    None =>
      match self.question {
        Some(channel) =>
          if tool_names.contains("ask_question") {
            Some(
              CetasParentQuestionEndpoint::CetasParentQuestionEndpoint(
                channel~,
                child_session=spec.session_id,
              )
              as &@askquestion.QuestionEndpoint,
            )
          } else {
            None
          }
        None => None
      }
  }
  for ext in self.tool_extensions(tool_names, question~) {
    exts.push(ext)
  }
  // Worker reporting is a ticket face, not a generic child face: the ticket
  // binding lives in the host endpoint, so a child composed without one gets
  // no `report_progress` / `submit_work_report` tools at all.
  match self.reporting {
    Some(endpoint) =>
      exts.push(
        TicketReportTools::TicketReportTools(endpoint~) as &@posoco.Extension,
      )
    None => ()
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
