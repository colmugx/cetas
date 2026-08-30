///|
/// White-box tests for the ctx-injected default feature set: the six
/// context-free tools plus skills discovery through the injected Workspace
/// port.

///|
/// Minimal WorkspaceFs fake that can serve one repository skill. Only the
/// operations skills discovery touches are implemented; everything else
/// raises "unsupported".
priv struct SkillsCtxFs {
  files : Map[String, String]
  dirs : Map[String, Array[String]]
}

///|
impl @workspace.WorkspaceFs for SkillsCtxFs with fn exists(self, path) {
  self.files.contains(path) || self.dirs.contains(path)
}

///|
impl @workspace.WorkspaceFs for SkillsCtxFs with fn kind(
  self,
  path,
  follow_symlink~,
) {
  let _ = follow_symlink
  if self.files.contains(path) {
    @workspace.WorkspaceFileKind::File
  } else if self.dirs.contains(path) {
    @workspace.WorkspaceFileKind::Dir
  } else {
    raise @workspace.WorkspaceFsError::WorkspaceFsError("missing: " + path)
  }
}

///|
impl @workspace.WorkspaceFs for SkillsCtxFs with fn read_file(self, path) {
  match self.files.get(path) {
    Some(content) => content
    None => raise @workspace.WorkspaceFsError::WorkspaceFsError("missing")
  }
}

///|
impl @workspace.WorkspaceFs for SkillsCtxFs with fn write_file(
  _self,
  _path,
  _content,
) {
  raise @workspace.WorkspaceFsError::WorkspaceFsError("unsupported")
}

///|
impl @workspace.WorkspaceFs for SkillsCtxFs with fn write_file_atomic(
  _self,
  _path,
  _content,
) {
  raise @workspace.WorkspaceFsError::WorkspaceFsError("unsupported")
}

///|
impl @workspace.WorkspaceFs for SkillsCtxFs with fn remove(_self, _path) {
  raise @workspace.WorkspaceFsError::WorkspaceFsError("unsupported")
}

///|
impl @workspace.WorkspaceFs for SkillsCtxFs with fn rename(
  _self,
  _from,
  _to_,
  replace~,
) {
  let _ = replace
  raise @workspace.WorkspaceFsError::WorkspaceFsError("unsupported")
}

///|
impl @workspace.WorkspaceFs for SkillsCtxFs with fn realpath(_self, path) {
  path
}

///|
impl @workspace.WorkspaceFs for SkillsCtxFs with fn readdir(
  self,
  path,
  include_hidden~,
) {
  let _ = include_hidden
  match self.dirs.get(path) {
    Some(entries) => entries.copy()
    None => raise @workspace.WorkspaceFsError::WorkspaceFsError("missing")
  }
}

///|
impl @workspace.WorkspaceFs for SkillsCtxFs with fn walk(
  _self,
  _root,
  _callback,
) {
  raise @workspace.WorkspaceFsError::WorkspaceFsError("unsupported")
}

///|
impl @workspace.WorkspaceFs for SkillsCtxFs with fn mkdir(
  _self,
  _path,
  recursive~,
) {
  let _ = recursive
  raise @workspace.WorkspaceFsError::WorkspaceFsError("unsupported")
}

///|
async test "default features include discovered skills through injected ctx" {
  let fs = SkillsCtxFs::{
    files: Map::from_array([
      (
        "/repo/.agents/skills/demo/SKILL.md", "---\nname: demo\ndescription: Demo skill\n---\nDo the demo.",
      ),
    ]),
    dirs: Map::from_array([
      ("/repo", [".agents"]),
      ("/repo/.agents", ["skills"]),
      ("/repo/.agents/skills", ["demo"]),
      ("/repo/.agents/skills/demo", ["SKILL.md"]),
    ]),
  }
  let exts = build_default_features(
    ctx={ fs, cwd: "/repo", home: "/home/u", },
    enable_nmem=false,
    detect_herdr=false,
  )
  // Seven context-free tools (read/write/edit/glob/grep/webfetch), the RTK
  // hook, the skills extension (with the built-in manuals merged in), the
  // forme self-description extension, and the handoff extension.
  // enable_nmem=false pins the count against dev machines with CETAS_NMEM=1
  // or an on-baked nmem_target knob.
  assert_eq(exts.length(), 11)
  let ids : Array[String] = []
  for ext in exts {
    ids.push(ext.extension_id())
  }
  assert_true(ids.contains("posoco_ext_skills"))
  assert_true(ids.contains("forme"))
  assert_true(ids.contains("posoco_ext_webfetch"))
  // The skills extension contributes its ToolProvider (activating both
  // activate_skill and read_skill_resource) and the host-facing `skills`
  // command on a populated catalog.
  for ext in exts {
    if ext.extension_id() == "posoco_ext_skills" {
      let manifest = ext.manifest()
      assert_eq(manifest.tools.length(), 1)
      assert_eq(manifest.tools[0].list_tools().length(), 2)
      assert_eq(manifest.commands.length(), 1)
    }
  }
}

///|
async test "enable_nmem registers the nowledge-mem extension" {
  let fs = SkillsCtxFs::{
    files: Map::from_array([]),
    dirs: Map::from_array([]),
  }
  let ctx : HostContext = { fs, cwd: "/nowhere", home: "/home/u", }
  // Explicitly off build: no memory tools, no boot drain — nothing
  // registers, independent of the baked knob or dev-machine env.
  let off = build_default_features(ctx~, enable_nmem=false, detect_herdr=false)
  let mut off_found = false
  for ext in off {
    if ext.extension_id() == "posoco_ext_nowledge_mem" {
      off_found = true
    }
  }
  assert_false(off_found)
  // Opt-in build: the default set plus Nowledge Mem.
  let on = build_default_features(ctx~, enable_nmem=true, detect_herdr=false)
  assert_eq(on.length(), 12)
  let mut found = false
  for ext in on {
    if ext.extension_id() == "posoco_ext_nowledge_mem" {
      found = true
      // One ToolProvider with the eight default tools (the five official MCP
      // names plus posoco additions; memory_delete hidden,
      // thread_create dropped with the CLI runner — no MCP counterpart),
      // the passive MemoryPort view, the /memory command, and prompt
      // guidance.
      let manifest = ext.manifest()
      assert_eq(manifest.tools.length(), 1)
      assert_eq(manifest.tools[0].list_tools().length(), 8)
      assert_eq(manifest.memory.length(), 1)
      assert_eq(manifest.commands.length(), 1)
      assert_eq(manifest.commands[0].commands()[0].id, "memory")
      assert_eq(manifest.prompt_contributors.length(), 1)
    }
  }
  assert_true(found)
}

///|
async test "default features register skills even with no discovered skills: the builtin manuals ride along" {
  let fs = SkillsCtxFs::{
    files: Map::from_array([]),
    dirs: Map::from_array([]),
  }
  let exts = build_default_features(
    ctx={ fs, cwd: "/nowhere", home: "/home/u", },
    enable_nmem=false,
    detect_herdr=false,
  )
  // An empty environment still registers the skills extension: the built-in
  // manuals (cetas-about/usage/config) are merged into the catalog, so both
  // skill tools stay live and the `skills` command always has content.
  assert_eq(exts.length(), 11)
  let mut found = false
  for ext in exts {
    if ext.extension_id() == "posoco_ext_skills" {
      found = true
      let manifest = ext.manifest()
      assert_eq(manifest.tools.length(), 1)
      let tool_names : Array[String] = []
      for tool in manifest.tools[0].list_tools() {
        tool_names.push(tool.name.to_string())
      }
      assert_true(tool_names.contains("activate_skill"))
      assert_true(tool_names.contains("read_skill_resource"))
      assert_eq(manifest.commands.length(), 1)
    }
  }
  assert_true(found)
}

///|
async test "forme registers with /help and its prompt note; host note flows through" {
  let fs = SkillsCtxFs::{
    files: Map::from_array([]),
    dirs: Map::from_array([]),
  }
  let exts = build_default_features(
    ctx={ fs, cwd: "/nowhere", home: "/home/u", },
    enable_nmem=false,
    detect_herdr=false,
    host_help_note=Some("ESC — interrupt the turn"),
  )
  let mut found = false
  for ext in exts {
    if ext.extension_id() == "forme" {
      found = true
      let manifest = ext.manifest()
      assert_eq(manifest.commands.length(), 1)
      assert_eq(manifest.commands[0].commands()[0].id, "help")
      assert_eq(manifest.prompt_contributors.length(), 1)
      match manifest.commands[0].invoke("help", Json::null()) {
        @posoco.CommandOutcome::Success(feedback~, ..) =>
          assert_true(feedback.contains("ESC — interrupt the turn"))
        _ => fail("/help must succeed with the host note")
      }
    }
  }
  assert_true(found)
}

// ------------------------------------------------------------ ask_question (ui~)

///|
/// Minimal UiPort fake: no rendering, no interactive answers. Only the
/// presence/absence of the port decides feature registration; interactive
/// behavior is askquestion's own test surface.
priv struct HeadlessUi {}

///|
impl @posoco.UiPort for HeadlessUi with fn ui_descriptor(_self) -> @posoco.UiDescriptor {
  @posoco.UiDescriptor::empty()
}

///|
impl @posoco.UiPort for HeadlessUi with fn render(_self, _intent) -> Unit {
  ()
}

///|
impl @posoco.UiPort for HeadlessUi with fn request(_self, _req) -> @posoco.UiResponse {
  raise @posoco.UiError::Unsupported(detail="headless test ui")
}

///|
async test "ask_question registers only when the host supplies a UI port" {
  let fs = SkillsCtxFs::{
    files: Map::from_array([]),
    dirs: Map::from_array([]),
  }
  let ctx : HostContext = { fs, cwd: "/nowhere", home: "/home/u", }
  // Without a UI port: seven tools + RTK hook + skills + forme + handoff,
  // no ask_question.
  let bare = build_default_features(ctx~, enable_nmem=false, detect_herdr=false)
  assert_eq(bare.length(), 11)
  let bare_ids : Array[String] = []
  for ext in bare {
    bare_ids.push(ext.extension_id())
  }
  assert_false(bare_ids.contains("posoco_ext_askquestion"))
  // With a UI port: ask_question joins the default set and contributes
  // exactly the ask_question ToolProvider plus prompt guidance.
  let with_ui = build_default_features(
    ctx~,
    ui=Some(HeadlessUi::{ } as &@posoco.UiPort),
    enable_nmem=false,
    detect_herdr=false,
  )
  assert_eq(with_ui.length(), 12)
  let mut found = false
  for ext in with_ui {
    if ext.extension_id() == "posoco_ext_askquestion" {
      found = true
      let manifest = ext.manifest()
      assert_eq(manifest.tools.length(), 1)
      assert_eq(manifest.tools[0].list_tools().length(), 1)
      assert_eq(
        manifest.tools[0].list_tools()[0].name.to_string(),
        "ask_question",
      )
      assert_eq(manifest.prompt_contributors.length(), 1)
    }
  }
  assert_true(found)
}
