///|
/// child_composer.mbt — the real `@subagent.ChildComposer` over a shared
/// `CetasPlatform` (design §3.1/§3.6): every spawn composes a fresh child
/// Agent from the platform's providers, credentials, and catalogs ("same
/// cetas"), while everything else is independent and trimmed at composition
/// time ("组装时就少给"): model slot/effort override, a fixed tool face, an
/// optional skills whitelist, the kind permission posture with the in-process
/// AutoApprove source (§6.2), and optional context/observer riders. Session
/// persistence rides the platform JSONL store only when resuming; otherwise
/// the child is in-memory by omission. No ui, nmem, herdr, gateway,
/// ratelimit, handoff, or forme joins a child, and the face never contains
/// `agent`/`agent_swarm` — depth 1 is structural.
///
/// The v1 tool face is fixed to {read, write, edit, glob, grep, bash}; an
/// unknown name fails the compose with a model-visible error instead of a
/// silent drop.

///|
/// The real child composer: shares the platform's provider machinery and
/// gives every child its own `FreshnessGuard` and a fresh `WorkspaceAnchor`
/// rooted at the platform cwd (§3.6 — 同根新实例、每子独立 guard).
pub struct PlatformChildComposer {
  platform : CetasPlatform
}

///|
pub fn PlatformChildComposer::PlatformChildComposer(
  platform~ : CetasPlatform,
) -> PlatformChildComposer {
  { platform, }
}

///|
/// Filter the discovered catalog to the whitelisted skill ids. ChildSpec
/// `skills`: `Some(list)` is a whitelist over discovered skills (unknown ids
/// are simply absent — a whitelist is an upper bound, not a requirement);
/// `Some([])` keeps everything discovered; `None` never reaches here. The
/// builtin product manuals merge in after the filter, so they stay present
/// regardless of the whitelist.
fn filter_skill_catalog(
  catalog : @skills.SkillCatalog,
  allow : Array[String],
) -> @skills.SkillCatalog {
  let skills : Array[@skills.SkillDescriptor] = []
  for skill in catalog.skills {
    if allow.contains(skill.name) {
      skills.push(skill)
    }
  }
  { skills, diagnostics: catalog.diagnostics, }
}

///|
/// Carrier that mounts the child's observers onto the composed Agent so
/// child events reach the extension's subscription channel (§3.3).
priv struct ObserverCarrier {
  observers : Array[&@posoco.Observer]
}

///|
fn ObserverCarrier::ObserverCarrier(
  observers~ : Array[&@posoco.Observer],
) -> ObserverCarrier {
  { observers, }
}

///|
impl @posoco.Extension for ObserverCarrier with fn extension_id(_self) -> String {
  "cetas_core.child_observers"
}

///|
impl @posoco.Extension for ObserverCarrier with fn manifest(self) -> @posoco.ExtensionManifest {
  let m = @posoco.ExtensionManifest::empty(id="cetas_core.child_observers")
  { ..m, observers: self.observers, }
}

///|
/// Carrier that mounts the project-context contributor when the child
/// inherits context files (`ChildSpec.context_files`); same ns as the parent
/// session's contributor.
priv struct ContextPromptCarrier {
  contributor : &@posoco.SystemPromptContributor
}

///|
fn ContextPromptCarrier::ContextPromptCarrier(
  contributor~ : &@posoco.SystemPromptContributor,
) -> ContextPromptCarrier {
  { contributor, }
}

///|
impl @posoco.Extension for ContextPromptCarrier with fn extension_id(_self) -> String {
  "cetas_core.child_context"
}

///|
impl @posoco.Extension for ContextPromptCarrier with fn manifest(self) -> @posoco.ExtensionManifest {
  let m = @posoco.ExtensionManifest::empty(id="cetas_core.child_context")
  { ..m, prompt_contributors: [self.contributor], }
}

///|
/// Per-child in-memory session store (design §3.1): fresh children keep their
/// history in memory only; `resuming` swaps in the platform JSONL store.
/// Missing ids load as empty sessions, mirroring the fs store's semantics.
priv struct ChildMemoryStore {
  sessions : Map[String, @posoco.Session]
}

///|
fn ChildMemoryStore::ChildMemoryStore() -> ChildMemoryStore {
  { sessions: Map::from_array([]), }
}

///|
impl @posoco.SessionStore for ChildMemoryStore with fn load(self, id : String) -> @posoco.Session raise @posoco.SessionError {
  match self.sessions.get(id) {
    Some(session) => session
    None => @posoco.Session::{ messages: [], metadata: Map::from_array([]), }
  }
}

///|
impl @posoco.SessionStore for ChildMemoryStore with fn save(
  self,
  id : String,
  session : @posoco.Session,
) -> Unit raise @posoco.SessionError {
  self.sessions[id] = session
}

///|
impl @posoco.Extension for ChildMemoryStore with fn extension_id(_self) -> String {
  "cetas_core.child_memory_store"
}

///|
impl @posoco.Extension for ChildMemoryStore with fn manifest(self) -> @posoco.ExtensionManifest {
  let m = @posoco.ExtensionManifest::empty(id="cetas_core.child_memory_store")
  { ..m, sessions: [self as &@posoco.SessionStore], }
}

///|
/// Build the child's extensions from the spec — everything except the router:
/// the trimmed tool face, the skills extension under the whitelist, the kind
/// permission posture with AutoApprove, the context/observer riders, and the
/// session store (in-memory by default, the platform JSONL store when
/// resuming).
async fn child_exts(
  platform : CetasPlatform,
  spec : @subagent.ChildSpec,
) -> Array[&@posoco.Extension] raise @subagent.ComposerError {
  let freshness = @devkit.FreshnessGuard::FreshnessGuard()
  let anchor = @devkit.WorkspaceAnchor::WorkspaceAnchor(platform.cwd)
  let exts : Array[&@posoco.Extension] = []
  for name in spec.tools {
    match name {
      "read" =>
        exts.push(
          @read.ReadTools(freshness~, anchor=Some(anchor)) as &@posoco.Extension,
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
      "bash" =>
        exts.push(@bash.ShellTools(anchor=Some(anchor)) as &@posoco.Extension)
      other =>
        raise @subagent.ComposerError::Failed(
          "unknown tool '\{other}' for child face (supported: read, write, edit, glob, grep, bash)",
        )
    }
  }
  match spec.skills {
    Some(allow) => {
      let discovered = match
        @skills.Skills::discover(
          platform.fs,
          cwd=platform.cwd,
          home=platform.home,
          config=cetas_skills_config(),
        ) {
        Some(skills) => skills.catalog()
        None => @skills.SkillCatalog::empty()
      }
      let catalog = if allow.length() > 0 {
        filter_skill_catalog(discovered, allow)
      } else {
        discovered
      }
      match
        @skills.Skills::from_catalog(
          platform.fs,
          catalog=@skills.merge_builtin_skills(
            catalog,
            @forme.builtin_manual_skills(),
          ),
          config=cetas_skills_config(),
        ) {
        Ok(skills) => exts.push(skills as &@posoco.Extension)
        Err(_) => ()
      }
    }
    None => ()
  }
  // Unattended posture (§6.2): the child never surfaces an approval dialog —
  // AutoApprove answers AllowAlways while the kind mode keeps its semantics
  // (ReadOnly still hard-rejects writes at the policy level).
  exts.push(
    @permission.PermissionPolicy(
      spec.mode,
      approval=Some(@kit.AutoApprove() as &@permission.ApprovalSource),
    )
    as &@posoco.Extension,
  )
  if spec.context_files {
    // Context files are best-effort: a read failure never blocks composition.
    let loader = @context.ContextLoader(platform.fs, home=platform.home)
    let bundle = loader.load(platform.cwd) catch {
      _ => @context.ContextBundle::empty()
    }
    exts.push(
      ContextPromptCarrier(
        contributor=@context.ContextPromptContributor(bundle~, ns="cetas")
          as &@posoco.SystemPromptContributor,
      )
      as &@posoco.Extension,
    )
  }
  if spec.observers.length() > 0 {
    exts.push(ObserverCarrier(observers=spec.observers) as &@posoco.Extension)
  }
  if spec.resuming {
    exts.push(platform.session_store as &@posoco.Extension)
  } else {
    exts.push(ChildMemoryStore() as &@posoco.Extension)
  }
  exts
}

///|
/// Assemble the child Agent for one spawn. The slot override fail-fasts:
/// unlike the parent hosts (warn-and-keep), a child has no fallback — an
/// unknown slot or a rejected effort must fail the compose.
pub impl @subagent.ChildComposer for PlatformChildComposer with fn compose(
  self : PlatformChildComposer,
  spec : @subagent.ChildSpec,
) -> @posoco.Agent raise @subagent.ComposerError {
  let exts = child_exts(self.platform, spec)
  let router = build_cetas_router(platform=self.platform) catch {
    error =>
      raise @subagent.ComposerError::Failed(
        "child router build failed: \{error.to_string()}",
      )
  }
  let selection = ActiveModelSelection::from_current(spec.slot, spec.effort)
  let resolved = resolve_default_slot_id(
    self.platform.catalogs,
    Some(selection),
  )
  if resolved != spec.slot {
    raise @subagent.ComposerError::Failed(
      "slot '\{spec.slot}' not present in platform catalogs (available: \{router.list_slot_ids().join(", ")})",
    )
  }
  router.switch_slot(spec.slot) catch {
    error =>
      raise @subagent.ComposerError::Failed(
        "model slot '\{spec.slot}' switch failed: \{error.to_string()}",
      )
  }
  match spec.effort {
    Some(effort) =>
      router.select_effort(spec.slot, effort) catch {
        error =>
          raise @subagent.ComposerError::Failed(
            "effort '\{effort}' rejected by model slot '\{spec.slot}': \{error.to_string()}",
          )
      }
    None => ()
  }
  exts.push(router as &@posoco.Extension)
  @posoco.Agent(
    exts~,
    config=default_agent_config(system_prompt=Some(spec.system_prompt)),
  ) catch {
    error =>
      raise @subagent.ComposerError::Failed(
        "child agent composition failed: \{error.to_string()}",
      )
  }
}

///|
pub extend PlatformChildComposer with @subagent.ChildComposer::{compose}
