///|
/// child_composer_wbtest.mbt — whitebox coverage for the real ChildComposer:
/// the trimmed tool face, the AutoApprove permission posture (ReadOnly hard
/// reject vs WorkspaceWrite pass), fail-fast slot/effort overrides, the
/// resume-only session store, the skills whitelist filter, and the
/// context/observer riders. Ships the in-memory FakeFs the composer's
/// platform assembly needs.

///|
/// In-memory WorkspaceFs with per-operation failure injection, mirroring the
/// posoco-ext-credentials wbtest fake.
priv struct FakeFs {
  files : Map[String, String]
  fail_ops : Map[String, Bool]
}

///|
fn FakeFs::FakeFs() -> FakeFs {
  { files: Map::from_array([]), fail_ops: Map::from_array([]), }
}

///|
fn FakeFs::should_fail(self : FakeFs, op : String) -> Bool {
  self.fail_ops.get(op) is Some(true)
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn exists(self, path) {
  if self.should_fail("exists") {
    raise @workspace.WorkspaceFsError::WorkspaceFsError("exists failed")
  }
  self.files.contains(path)
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn kind(
  _self,
  _path,
  follow_symlink~,
) {
  let _ = follow_symlink
  @workspace.WorkspaceFileKind::File
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn read_file(self, path) {
  if self.should_fail("read_file") {
    raise @workspace.WorkspaceFsError::WorkspaceFsError("read failed")
  }
  match self.files.get(path) {
    Some(content) => content
    None => raise @workspace.WorkspaceFsError::WorkspaceFsError("missing")
  }
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn write_file(self, path, content) {
  if self.should_fail("write_file") {
    raise @workspace.WorkspaceFsError::WorkspaceFsError("write failed")
  }
  self.files[path] = content
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn write_file_atomic(
  self,
  path,
  content,
) {
  if self.should_fail("write_file_atomic") {
    raise @workspace.WorkspaceFsError::WorkspaceFsError("atomic write failed")
  }
  self.files[path] = content
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn remove(self, path) {
  if self.should_fail("remove") {
    raise @workspace.WorkspaceFsError::WorkspaceFsError("remove failed")
  }
  ignore(self.files.remove(path))
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn rename(
  _self,
  _from,
  _to,
  replace~,
) {
  let _ = replace
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn realpath(_self, path) {
  path
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn readdir(
  _self,
  _path,
  include_hidden~,
) {
  let _ = include_hidden
  []
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn walk(_self, _root, _callback) {

}

///|
impl @workspace.WorkspaceFs for FakeFs with fn mkdir(self, _path, recursive~) {
  let _ = recursive
  if self.should_fail("mkdir") {
    raise @workspace.WorkspaceFsError::WorkspaceFsError("mkdir failed")
  }
}

///|
/// Claude slot for the swapped catalog: advertises a "high" effort through a
/// rebuild hook so the composer's select_effort path is exercisable.
fn child_wb_claude_slot(port : &@posoco.ModelPort) -> @llm.ModelSlot {
  @llm.ModelSlot::ModelSlot(
    id="opencode/claude-sonnet-5",
    label="Claude",
    provider_id="opencode",
    model_id="claude-sonnet-5",
    port~,
    thinking_efforts=["high"],
    rebuild_on_effort=Some(fn(_effort : String) { child_wb_claude_slot(port) }),
  )
}

///|
/// FakeFs platform with the opencode catalog swapped so both slots carry
/// scripted models: "opencode/claude-sonnet-5" drives `model`, the codex slot
/// a spare. Mirrors the platform_wbtest assembly precedent.
async fn child_wb_platform(
  model~ : @posoco.ScriptedModel,
  cwd~ : String,
) -> @cetas_core.CetasPlatform {
  let fs = FakeFs()
  fs.files["/home/.cetas/settings.json"] = "{\"providers\":{\"opencode\":{\"api_key\":\"sk-zen-test\"}}}"
  fs.files["/home/.cetas/model_lists.json"] = "{\"opencode\":[{\"model_id\":\"claude-sonnet-5\",\"thinking_efforts\":[],\"default_effort\":null,\"context_window\":null},{\"model_id\":\"gpt-5.1-codex\",\"thinking_efforts\":[],\"default_effort\":null,\"context_window\":null}]}"
  let platform = @cetas_core.build_cetas_platform(
    home="/home",
    cwd~,
    fs,
    permission_mode=@permission.WorkspaceWrite,
  )
  @cetas_core.swap_platform_catalog(
    platform.catalogs,
    "opencode",
    @llm.ProviderModelCatalog::ProviderModelCatalog(provider_id="opencode", slots=[
      child_wb_claude_slot(model),
      @llm.ModelSlot::ModelSlot(
        id="opencode/gpt-5.1-codex",
        label="Codex",
        provider_id="opencode",
        model_id="gpt-5.1-codex",
        port=@posoco.ScriptedModel([]),
      ),
    ]),
  )
  platform
}

///|
fn child_wb_spec(
  tools~ : Array[String],
  mode~ : @permission.PermissionMode,
  slot~ : String,
  skills? : Array[String]? = None,
  effort? : String? = None,
  resuming? : Bool = false,
  context_files? : Bool = false,
  observers? : Array[&@posoco.Observer] = [],
) -> @subagent.ChildSpec {
  {
    task: "write notes",
    kind_name: "coder",
    session_id: "child-1",
    resuming,
    tools,
    skills,
    mode,
    system_prompt: "child system prompt",
    slot,
    effort,
    context_files,
    observers,
  }
}

///|
/// Model-visible tool names across the whole extension list.
fn child_wb_tool_names(exts : Array[&@posoco.Extension]) -> Array[String] {
  let names : Array[String] = []
  for ext in exts {
    for provider in ext.manifest().tools {
      for def in provider.list_tools() {
        names.push(def.name.to_string())
      }
    }
  }
  names
}

///|
fn child_wb_has_ext(exts : Array[&@posoco.Extension], id : String) -> Bool {
  for ext in exts {
    if ext.extension_id() == id {
      return true
    }
  }
  false
}

///|
fn child_wb_session_stores(exts : Array[&@posoco.Extension]) -> Int {
  let mut total = 0
  for ext in exts {
    total = total + ext.manifest().sessions.length()
  }
  total
}

///|
async test "the child tool face is exactly the spawn whitelist plus the AutoApprove policy" {
  let platform = child_wb_platform(model=@posoco.ScriptedModel([]), cwd="/w")
  let scout = child_exts(
    platform,
    child_wb_spec(
      tools=["read", "glob", "grep"],
      mode=@permission.ReadOnly,
      slot="opencode/claude-sonnet-5",
    ),
  )
  assert_eq(child_wb_tool_names(scout), ["read", "glob", "grep"])
  assert_true(child_wb_has_ext(scout, "posoco_ext_permission"))
  let coder = child_exts(
    platform,
    child_wb_spec(
      tools=["read", "write", "edit", "glob", "grep", "bash"],
      mode=@permission.WorkspaceWrite,
      slot="opencode/claude-sonnet-5",
    ),
  )
  assert_eq(child_wb_tool_names(coder), [
    "read", "write", "edit", "glob", "grep", "bash",
  ])
}

///|
async test "an unknown tool name fails the child compose with the supported list" {
  let platform = child_wb_platform(model=@posoco.ScriptedModel([]), cwd="/w")
  try
    ignore(
      child_exts(
        platform,
        child_wb_spec(
          tools=["read", "hack"],
          mode=@permission.ReadOnly,
          slot="opencode/claude-sonnet-5",
        ),
      ),
    )
  catch {
    @subagent.ComposerError::Failed(message) => {
      assert_true(message.contains("unknown tool 'hack'"))
      assert_true(
        message.contains("supported: read, write, edit, glob, grep, bash"),
      )
    }
  } noraise {
    _ => fail("an unknown tool must fail the child composition")
  }
}

///|
fn child_wb_skill(name : String) -> @skills.SkillDescriptor {
  @skills.SkillDescriptor::SkillDescriptor(
    name~,
    description="d",
    skill_md_path="/skills/\{name}/SKILL.md",
    skill_dir="/skills/\{name}",
    scope=@skills.SkillScope::Repository,
  )
}

///|
async test "skills join only when requested and the whitelist filters the catalog" {
  let platform = child_wb_platform(model=@posoco.ScriptedModel([]), cwd="/w")
  let plain = child_exts(
    platform,
    child_wb_spec(
      tools=["read"],
      mode=@permission.ReadOnly,
      slot="opencode/claude-sonnet-5",
    ),
  )
  assert_false(child_wb_has_ext(plain, "posoco_ext_skills"))
  let whitelisted = child_exts(
    platform,
    child_wb_spec(
      tools=["read"],
      mode=@permission.ReadOnly,
      slot="opencode/claude-sonnet-5",
      skills=Some(["x"]),
    ),
  )
  assert_true(child_wb_has_ext(whitelisted, "posoco_ext_skills"))
  let everything = child_exts(
    platform,
    child_wb_spec(
      tools=["read"],
      mode=@permission.ReadOnly,
      slot="opencode/claude-sonnet-5",
      skills=Some([]),
    ),
  )
  assert_true(child_wb_has_ext(everything, "posoco_ext_skills"))
  // The whitelist filter itself: only allowed ids survive, diagnostics ride along.
  let catalog : @skills.SkillCatalog = {
    skills: [child_wb_skill("keep-me"), child_wb_skill("drop-me")],
    diagnostics: [],
  }
  let filtered = filter_skill_catalog(catalog, ["keep-me"])
  assert_eq(filtered.skills.length(), 1)
  assert_eq(filtered.skills[0].name, "keep-me")
  assert_eq(filtered.diagnostics.length(), 0)
}

///|
async test "fresh children get an in-memory store; resuming swaps in the fs store" {
  let platform = child_wb_platform(model=@posoco.ScriptedModel([]), cwd="/w")
  let fresh = child_exts(
    platform,
    child_wb_spec(
      tools=["read"],
      mode=@permission.ReadOnly,
      slot="opencode/claude-sonnet-5",
    ),
  )
  // Exactly one store, and it is not the fs store: fresh children stay in memory.
  assert_eq(child_wb_session_stores(fresh), 1)
  assert_false(child_wb_has_ext(fresh, "posoco_ext_fs_session"))
  assert_true(child_wb_has_ext(fresh, "cetas_core.child_memory_store"))
  let resumed = child_exts(
    platform,
    child_wb_spec(
      tools=["read"],
      mode=@permission.ReadOnly,
      slot="opencode/claude-sonnet-5",
      resuming=true,
    ),
  )
  assert_eq(child_wb_session_stores(resumed), 1)
  assert_true(child_wb_has_ext(resumed, "posoco_ext_fs_session"))
  assert_false(child_wb_has_ext(resumed, "cetas_core.child_memory_store"))
}

///|
async test "context and observer riders join only when requested" {
  let platform = child_wb_platform(model=@posoco.ScriptedModel([]), cwd="/w")
  let plain = child_exts(
    platform,
    child_wb_spec(
      tools=["read"],
      mode=@permission.ReadOnly,
      slot="opencode/claude-sonnet-5",
    ),
  )
  assert_false(child_wb_has_ext(plain, "cetas_core.child_context"))
  assert_false(child_wb_has_ext(plain, "cetas_core.child_observers"))
  let observer = @posoco.RecordingObserver::RecordingObserver()
  let decorated = child_exts(
    platform,
    child_wb_spec(
      tools=["read"],
      mode=@permission.ReadOnly,
      slot="opencode/claude-sonnet-5",
      context_files=true,
      observers=[observer as &@posoco.Observer],
    ),
  )
  assert_true(child_wb_has_ext(decorated, "cetas_core.child_context"))
  assert_true(child_wb_has_ext(decorated, "cetas_core.child_observers"))
}

///|
/// A path no fs can ever create a file under, so a gate pass is observable as
/// a tool-level IO failure while nothing touches disk.
fn child_wb_impossible_path() -> String {
  "/dev/null/impossible/notes.txt"
}

///|
async test "a ReadOnly scout child hard-rejects write before IO despite AutoApprove" {
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_tool_call_response(
        "write",
        "call-1",
        Json::object(
          Map::from_array([
            ("path", Json::string(child_wb_impossible_path())),
            ("content", Json::string("hi")),
          ]),
        ),
      ),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("blocked")),
  ])
  let platform = child_wb_platform(model~, cwd="/w")
  let composer = PlatformChildComposer::PlatformChildComposer(platform~)
  let agent = composer.compose(
    child_wb_spec(
      tools=["read", "glob", "grep"],
      mode=@permission.ReadOnly,
      slot="opencode/claude-sonnet-5",
    ),
  )
  let result = agent.run_turn(
    @posoco.tk_user_msg("write notes"),
    "child-scout-1",
  )
  assert_eq(result.tool_results.length(), 1)
  match result.tool_results[0] {
    @posoco.ToolOutcome::NotExecuted(..) => ()
    other =>
      fail(
        "the ReadOnly gate must reject the write before IO, got: \{other.to_string()}",
      )
  }
  // The turn continues on the rejected call, so the model answers again.
  assert_eq(model.call_count(), 2)
}

///|
async test "a WorkspaceWrite coder child passes the write through the AutoApprove gate" {
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_tool_call_response(
        "write",
        "call-1",
        Json::object(
          Map::from_array([
            ("path", Json::string(child_wb_impossible_path())),
            ("content", Json::string("hi")),
          ]),
        ),
      ),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("done")),
  ])
  let platform = child_wb_platform(model~, cwd="/w")
  let composer = PlatformChildComposer::PlatformChildComposer(platform~)
  let agent = composer.compose(
    child_wb_spec(
      tools=["read", "write", "edit", "glob", "grep", "bash"],
      mode=@permission.WorkspaceWrite,
      slot="opencode/claude-sonnet-5",
    ),
  )
  let result = agent.run_turn(
    @posoco.tk_user_msg("write notes"),
    "child-coder-1",
  )
  assert_eq(result.tool_results.length(), 1)
  match result.tool_results[0] {
    @posoco.ToolOutcome::NotExecuted(..) =>
      fail("the AutoApprove policy must not reject the coder's write")
    other =>
      // Gate passed; the write reached the tool and failed on the impossible
      // path (a model-visible tool error, the write ext's own contract).
      assert_true(other.is_failure())
  }
  assert_eq(model.call_count(), 2)
}

///|
async test "an unknown slot fails the child compose and names the available slots" {
  let platform = child_wb_platform(model=@posoco.ScriptedModel([]), cwd="/w")
  let composer = PlatformChildComposer::PlatformChildComposer(platform~)
  try
    ignore(
      composer.compose(
        child_wb_spec(
          tools=["read"],
          mode=@permission.ReadOnly,
          slot="opencode/missing",
        ),
      ),
    )
  catch {
    @subagent.ComposerError::Failed(message) => {
      assert_true(
        message.contains(
          "slot 'opencode/missing' not present in platform catalogs",
        ),
      )
      assert_true(message.contains("opencode/claude-sonnet-5"))
      assert_true(message.contains("opencode/gpt-5.1-codex"))
    }
  } noraise {
    _ => fail("an unknown slot must fail the child composition")
  }
}

///|
async test "a valid slot and advertised effort compose the child on the shared provider" {
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("warmup")),
  ])
  let platform = child_wb_platform(model~, cwd="/w")
  let composer = PlatformChildComposer::PlatformChildComposer(platform~)
  let agent = composer.compose(
    child_wb_spec(
      tools=["read"],
      mode=@permission.ReadOnly,
      slot="opencode/claude-sonnet-5",
      effort=Some("high"),
    ),
  )
  ignore(agent.run_turn(@posoco.tk_user_msg("hi"), "child-slot-1"))
  assert_eq(model.call_count(), 1)
}

///|
async test "an unadvertised effort fails the child compose (no fallback)" {
  let platform = child_wb_platform(model=@posoco.ScriptedModel([]), cwd="/w")
  let composer = PlatformChildComposer::PlatformChildComposer(platform~)
  try
    ignore(
      composer.compose(
        child_wb_spec(
          tools=["read"],
          mode=@permission.ReadOnly,
          slot="opencode/claude-sonnet-5",
          effort=Some("nope"),
        ),
      ),
    )
  catch {
    @subagent.ComposerError::Failed(message) =>
      assert_true(
        message.contains(
          "effort 'nope' rejected by model slot 'opencode/claude-sonnet-5'",
        ),
      )
  } noraise {
    _ => fail("an unadvertised effort must fail the child composition")
  }
}
