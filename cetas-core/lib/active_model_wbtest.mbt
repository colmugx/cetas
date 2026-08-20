///|
/// White-box tests for the persisted active-model selection: parse shape
/// rules, slot resolution, and the read/merge/write round-trip on an in-memory
/// WorkspaceFs (no real IO, runs on every target).

///|
/// In-memory WorkspaceFs with per-operation failure injection, mirroring the
/// posoco-ext-credentials wbtest fake.
priv struct FakeFs {
  files : Map[String, String]
  fail_ops : Map[String, Bool]
}

///|
fn FakeFs::new() -> FakeFs {
  { files: Map::from_array([]), fail_ops: Map::from_array([]) }
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
/// One catalog slot over a scripted model port; only id/thinking_efforts
/// matter for selection resolution.
fn tk_slot(id : String) -> @llm.ModelSlot {
  @llm.ModelSlot::ModelSlot(
    id~,
    label=id,
    provider_id="test",
    model_id=id,
    port=@posoco.ScriptedModel([]),
    thinking_efforts=["low", "high"],
    default_effort=Some("low"),
  )
}

///|
fn tk_catalog(
  slots : Array[@llm.ModelSlot],
) -> @llm.ProviderModelCatalog raise @posoco.CompositionError {
  @llm.ProviderModelCatalog::ProviderModelCatalog(provider_id="test", slots~)
}

// ------------------------------------------------------------------- parse

///|
test "parse: missing model key means no selection" {
  let json = @json.parse("{\"providers\":{}}") catch {
    _ => fail("fixture must parse")
  }
  assert_true(parse_active_model_selection(json) is None)
}

///|
test "parse: valid flat keys round into a selection" {
  let json = @json.parse(
    "{\"model\":\"qwen/glm-4.6\",\"reasoning_effort\":\"high\"}",
  ) catch {
    _ => fail("fixture must parse")
  }
  match parse_active_model_selection(json) {
    Some({ slot, effort }) => {
      assert_eq(slot, "qwen/glm-4.6")
      assert_eq(effort, Some("high"))
    }
    None => fail("expected a selection")
  }
}

///|
test "parse: wrong shapes fail loudly instead of being sanitized" {
  let bad_model = @json.parse("{\"model\":42}") catch {
    _ => fail("fixture must parse")
  }
  try parse_active_model_selection(bad_model) catch {
    @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
      assert_true(detail.contains("model"))
    _ => fail("expected ManifestSchemaError for model shape")
  } noraise {
    _ => fail("expected model shape to raise")
  }
  let bad_effort = @json.parse("{\"model\":\"a/b\",\"reasoning_effort\":[]}") catch {
    _ => fail("fixture must parse")
  }
  try parse_active_model_selection(bad_effort) catch {
    @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
      assert_true(detail.contains("reasoning_effort"))
    _ => fail("expected ManifestSchemaError for effort shape")
  } noraise {
    _ => fail("expected effort shape to raise")
  }
}

// ----------------------------------------------------------------- resolve

///|
test "resolve: no selection or drifted slot keeps the router default" {
  let catalogs = [tk_catalog([tk_slot("a/x"), tk_slot("b/y")])]
  assert_eq(resolve_default_slot_id(catalogs, None), "")
  let drifted = Some({ slot: "gone/z", effort: None })
  assert_eq(resolve_default_slot_id(catalogs, drifted), "")
}

///|
test "resolve: a live selection wins over slot order" {
  let catalogs = [tk_catalog([tk_slot("a/x"), tk_slot("b/y")])]
  let selected = Some({ slot: "b/y", effort: Some("high") })
  assert_eq(resolve_default_slot_id(catalogs, selected), "b/y")
}

// ----------------------------------------------------------- read + write

///|
async test "read: missing file is no selection, malformed file is loud" {
  let fs = FakeFs::new()
  assert_true(read_active_model_selection(fs, home="/h") is None)
  fs.files["/h/.cetas/settings.json"] = "not json"
  try read_active_model_selection(fs, home="/h") catch {
    @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
      assert_true(detail.contains("not valid JSON"))
    _ => fail("expected ManifestSchemaError for malformed file")
  } noraise {
    _ => fail("expected malformed file to raise")
  }
}

///|
/// Fields of a parsed JSON object, for tests that inspect written settings.
fn tk_object_fields(json : Json, what~ : String) -> Map[String, Json] raise {
  match json {
    Json::Object(fields) => fields
    _ => fail(what + " must be a JSON object")
  }
}

///|
async test "write/read round-trip preserves unknown keys and drops effort on None" {
  let fs = FakeFs::new()
  fs.files["/h/.cetas/settings.json"] = "{\"providers\":{\"kimi\":{}},\"unknown\":1,\"model\":\"old/a\",\"reasoning_effort\":\"low\"}"
  write_active_model_selection(
    fs,
    home="/h",
    ActiveModelSelection::new("b/y", effort="high"),
  )
  let written = @json.parse(fs.files["/h/.cetas/settings.json"]) catch {
    _ => fail("written settings must parse")
  }
  let fields = tk_object_fields(written, what="written settings")
  assert_true(fields.get("providers") is Some(Json::Object({ .. })))
  assert_true(fields.get("unknown") is Some(Json::Number(_)))
  assert_true(fields.get("model") is Some(Json::String("b/y")))
  assert_true(fields.get("reasoning_effort") is Some(Json::String("high")))
  // Round-trip through the read path.
  match read_active_model_selection(fs, home="/h") {
    Some({ slot, effort }) => {
      assert_eq(slot, "b/y")
      assert_eq(effort, Some("high"))
    }
    None => fail("expected to read back the written selection")
  }
  // effort=None removes the key instead of writing a null.
  write_active_model_selection(fs, home="/h", ActiveModelSelection::new("b/y"))
  let cleared = @json.parse(fs.files["/h/.cetas/settings.json"]) catch {
    _ => fail("written settings must parse")
  }
  let cleared_fields = tk_object_fields(cleared, what="cleared settings")
  assert_true(cleared_fields.get("model") is Some(Json::String("b/y")))
  assert_true(cleared_fields.get("reasoning_effort") is None)
}

///|
async test "write: missing file starts from {} and malformed file is never clobbered" {
  let fs = FakeFs::new()
  write_active_model_selection(
    fs,
    home="/h",
    ActiveModelSelection::new("a/x", effort="low"),
  )
  let fresh = @json.parse(fs.files["/h/.cetas/settings.json"]) catch {
    _ => fail("fresh settings must parse")
  }
  let fresh_fields = tk_object_fields(fresh, what="fresh settings")
  assert_true(fresh_fields.get("model") is Some(Json::String("a/x")))
  assert_true(fresh_fields.get("reasoning_effort") is Some(Json::String("low")))
  fs.files["/h/.cetas/settings.json"] = "{broken"
  try
    write_active_model_selection(
      fs,
      home="/h",
      ActiveModelSelection::new("a/x"),
    )
  catch {
    @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
      assert_true(detail.contains("not valid JSON"))
    _ => fail("expected ManifestSchemaError for malformed file")
  } noraise {
    _ => fail("expected malformed file to make the write raise")
  }
  assert_eq(fs.files["/h/.cetas/settings.json"], "{broken")
}

///|
async test "write: fs failures surface as loud composition errors" {
  let fs = FakeFs::new()
  fs.fail_ops["write_file_atomic"] = true
  try
    write_active_model_selection(
      fs,
      home="/h",
      ActiveModelSelection::new("a/x"),
    )
  catch {
    @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
      assert_true(detail.contains("write failed"))
    _ => fail("expected ManifestSchemaError for fs write failure")
  } noraise {
    _ => fail("expected fs write failure to raise")
  }
  let read_fs = FakeFs::new()
  read_fs.files["/h/.cetas/settings.json"] = "{}"
  read_fs.fail_ops["read_file"] = true
  try
    write_active_model_selection(
      read_fs,
      home="/h",
      ActiveModelSelection::new("a/x"),
    )
  catch {
    @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
      assert_true(detail.contains("read failed"))
    _ => fail("expected ManifestSchemaError for fs read failure")
  } noraise {
    _ => fail("expected fs read failure to raise")
  }
}
