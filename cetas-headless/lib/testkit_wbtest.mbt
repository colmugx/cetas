///|
/// testkit_wbtest.mbt — shared whitebox fakes: an injectable scripted tty
/// (FakeTty), an in-memory WorkspaceFs (FakeFs, the core/acp precedent), and
/// a full-assembly scripted agent builder for the loop tests.

///|
/// Scripted terminal: `answers` are consumed in order; an exhausted script
/// is EOF. Every prompt/hint written by the code under test lands in
/// `writes`; `closed` records teardown.
priv struct FakeTty {
  answers : Array[String]
  writes : Array[String]
  mut cursor : Int
  mut closed : Bool
}

///|
fn FakeTty::FakeTty(answers : Array[String]) -> FakeTty {
  { answers, writes: [], cursor: 0, closed: false, }
}

///|
fn FakeTty::channel(self : FakeTty) -> TtyChannel {
  {
    read_line: fn() {
      if self.cursor < self.answers.length() {
        let answer = self.answers[self.cursor]
        self.cursor += 1
        Some(answer)
      } else {
        None
      }
    },
    write: fn(text : String) { self.writes.push(text) },
    close: fn() { self.closed = true },
  }
}

///|
/// The core wbtest FakeFs, verbatim shape: an in-memory file map behind the
/// WorkspaceFs port.
priv struct FakeFs {
  files : Map[String, String]
  dirs : Set[String]
}

///|
fn FakeFs::FakeFs() -> FakeFs {
  { files: Map::from_array([]), dirs: Set([]), }
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn exists(self, path) {
  self.files.contains(path) || self.dirs.contains(path)
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
  match self.files.get(path) {
    Some(content) => content
    None => raise @workspace.WorkspaceFsError::WorkspaceFsError("missing")
  }
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn write_file(self, path, content) {
  self.files[path] = content
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn write_file_atomic(
  self,
  path,
  content,
) {
  self.files[path] = content
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn remove(self, path) {
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
impl @workspace.WorkspaceFs for FakeFs with fn mkdir(self, path, recursive~) {
  let _ = recursive
  self.dirs.add(path)
}

///|
/// A canned approval ask.
fn tk_approval_request(
  tool_name~ : String,
  category~ : String,
) -> @permission.ApprovalRequest {
  {
    tool_name,
    call_id: "call-1",
    category,
    arguments_preview: "{\"path\": \"notes.txt\"}",
    arguments: Json::null(),
  }
}

///|
/// Seed a FakeFs settings root under a REAL temp home: the fs-session JSONL
/// store rides the native filesystem, so the home must be a writable real
/// path while settings stay fake and in-memory.
async fn tk_test_home(fs : FakeFs) -> String noraise {
  let home = @fs.tmpdir(prefix="cetas-headless-test-") catch {
    error =>
      abort("cetas-headless test fixture: tmpdir failed: \{error.to_string()}")
  }
  fs.files[home + "/.cetas/settings.json"] = "{\"providers\":{\"opencode\":{\"api_key\":\"sk-zen-test\"}}}"
  fs.files[home + "/.cetas/model_lists.json"] = "{\"opencode\":[{\"model_id\":\"claude-sonnet-5\",\"thinking_efforts\":[],\"default_effort\":null,\"context_window\":null}]}"
  home
}

///|
/// Compose a real agent over the full cetas-core assembly with a scripted
/// model in the single slot: the loop test rides the same seam as main, with
/// no network. Yolo mode keeps the turn free of approval gates. Returns the
/// agent plus the scripted model so tests can assert on the prompts the
/// model actually received (`received_messages`).
async fn tk_scripted_agent(
  steps : Array[@posoco.ScriptedModelStep],
  tail_exts? : Array[&@posoco.Extension] = [],
) -> (@posoco.Agent, @posoco.ScriptedModel) raise @posoco.CompositionError {
  let fs = FakeFs()
  let home = tk_test_home(fs)
  let platform = @cetas_core.build_cetas_platform(
    home~,
    cwd="/w",
    fs,
    permission_mode=@permission.Yolo,
  )
  let model = @posoco.ScriptedModel(steps)
  let slot = @llm.ModelSlot::ModelSlot(
    id="opencode/claude-sonnet-5",
    label="Claude",
    provider_id="opencode",
    model_id="claude-sonnet-5",
    port=model,
    thinking_efforts=[],
    context_window=None,
    default_effort=None,
  )
  @cetas_core.swap_platform_catalog(
    platform.catalogs,
    "opencode",
    @llm.ProviderModelCatalog::ProviderModelCatalog(provider_id="opencode", slots=[
      slot,
    ]),
  )
  let session = @cetas_core.build_cetas_session(
    platform~,
    cwd="/w",
    label="cetas-headless-tests",
  )
  (@cetas_core.compose_cetas_agent(session~, tail_exts~), model)
}
