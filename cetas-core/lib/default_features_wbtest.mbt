///|
/// White-box tests for the ctx-injected default feature set: the seven
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
    obsidian_vault=Some("test-vault"),
  )
  // The ten feature extensions (read/write/edit/glob/grep/astgrep/bash
  // direct, skills with the built-in manuals merged in, forme, handoff),
  // the three toolless gateway views (webfetch, nmem, obsidian), and the
  // gateway itself — the default compiled flavor is personal, so nmem and
  // obsidian register (rtk is lean-only now).
  assert_eq(exts.length(), 14)
  let ids : Array[String] = []
  for ext in exts {
    ids.push(ext.extension_id())
  }
  assert_true(ids.contains("posoco_ext_skills"))
  assert_true(ids.contains("forme"))
  assert_true(ids.contains("posoco_ext_webfetch"))
  assert_true(ids.contains("posoco_ext_lazytools"))
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
async test "nowledge-mem registers in the personal flavor" {
  let fs = SkillsCtxFs::{
    files: Map::from_array([]),
    dirs: Map::from_array([]),
  }
  let ctx : HostContext = { fs, cwd: "/nowhere", home: "/home/u", }
  // Personal builds bake nmem in: the default set plus Nowledge Mem.
  let exts = build_default_features(ctx~, obsidian_vault=Some("test-vault"))
  assert_eq(exts.length(), 14)
  let mut found = false
  let mut gateway_tools = 0
  for ext in exts {
    if ext.extension_id() == "posoco_ext_nowledge_mem" {
      found = true
      // The toolless view keeps the MemoryPort session briefing (core
      // injects it once per session behind its fixed lead line; the
      // <nmem-context> envelope itself is the extension's), the /memory
      // command, and prompt guidance — but its tool schemas now defer
      // behind the lazytools gateway.
      let manifest = ext.manifest()
      assert_eq(manifest.tools.length(), 0)
      assert_eq(manifest.memory.length(), 1)
      assert_eq(manifest.commands.length(), 1)
      assert_eq(manifest.commands[0].commands()[0].id, "memory")
      assert_eq(manifest.prompt_contributors.length(), 1)
    }
    if ext.extension_id() == "posoco_ext_lazytools" {
      gateway_tools = ext.manifest().tools[0].list_tools().length()
    }
  }
  assert_true(found)
  // The gateway exposes exactly its two meta tools (tool_list /
  // tool_execute); the deferred webfetch and nmem tools ride behind them.
  assert_eq(gateway_tools, 2)
}

///|
async test "default features register skills even with no discovered skills: the builtin manuals ride along" {
  let fs = SkillsCtxFs::{
    files: Map::from_array([]),
    dirs: Map::from_array([]),
  }
  let exts = build_default_features(
    ctx={ fs, cwd: "/nowhere", home: "/home/u", },
    obsidian_vault=Some("test-vault"),
  )
  // An empty environment still registers the skills extension: the built-in
  // manuals (cetas-about/usage/config) are merged into the catalog, so both
  // skill tools stay live and the `skills` command always has content.
  assert_eq(exts.length(), 14)
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
    host_help_note=Some("ESC — interrupt the turn"),
    obsidian_vault=Some("test-vault"),
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

// ------------------------------------------------------------ ask_question

///|
async test "ask_question always joins the default set" {
  let fs = SkillsCtxFs::{
    files: Map::from_array([]),
    dirs: Map::from_array([]),
  }
  let ctx : HostContext = { fs, cwd: "/nowhere", home: "/home/u", }
  // The default set (read/write/edit/glob/grep/astgrep/bash direct; skills,
  // forme, handoff), the three gateway views, the gateway ext, and
  // ask_question — which no longer depends on a host UI port: it resolves
  // the composed port from its CompositionView and reports "Interactive UI
  // is unavailable" per ask when none exists.
  let bare = build_default_features(ctx~, obsidian_vault=Some("test-vault"))
  assert_eq(bare.length(), 15)
  let mut found = false
  for ext in bare {
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
      assert_eq(manifest.requires, [@posoco.Capability::Ui])
    }
  }
  assert_true(found)
}

///|
async test "bash is a direct catalog tool; episodic tools defer" {
  let fs = SkillsCtxFs::{
    files: Map::from_array([]),
    dirs: Map::from_array([]),
  }
  let exts = build_default_features(
    ctx={ fs, cwd: "/nowhere", home: "/home/u", },
    obsidian_vault=Some("test-vault"),
  )
  let direct : Array[String] = []
  let mut gateway_meta = 0
  for ext in exts {
    for provider in ext.manifest().tools {
      for def in provider.list_tools() {
        let name = def.name.to_string()
        if name == "tool_list" || name == "tool_execute" {
          gateway_meta += 1
        } else if !direct.contains(name) {
          direct.push(name)
        }
      }
    }
  }
  // Direct surface: read/write/edit/glob/grep/astgrep/bash + the two skill
  // tools + ask_question — ten. Permission and rtk classify direct shell
  // calls by the tool name (unwrap passes them through unchanged), so bash
  // keeps its gating semantics without the gateway.
  assert_eq(gateway_meta, 2)
  assert_eq(direct.length(), 10)
  assert_true(direct.contains("bash"))
  // Episodic tools never appear directly: they are reachable only through
  // tool_execute (and discoverable via tool_list).
  assert_false(direct.contains("webfetch"))
  assert_false(direct.contains("memory_search"))
  assert_false(direct.contains("obsidian_search"))
}
