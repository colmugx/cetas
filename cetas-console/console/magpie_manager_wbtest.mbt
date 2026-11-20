///|
/// magpie_manager_wbtest.mbt — console Magpie manager integration tests.
///
/// Unit scenarios cover the host-settings matrix and the face projections
/// over a scripted `MagpieTransport` (no test contacts a gateway). The
/// integration scenario composes the real console runtime in a temp home and
/// flips the manager through `switch_model_manager` both ways.

///|
/// In-memory WorkspaceFs covering the settings/credential surface.
priv struct MagpieSettingsFs {
  files : Map[String, String]
}

///|
fn MagpieSettingsFs::MagpieSettingsFs() -> MagpieSettingsFs {
  { files: Map::from_array([]), }
}

///|
impl @workspace.WorkspaceFs for MagpieSettingsFs with fn exists(self, path) {
  self.files.contains(path)
}

///|
impl @workspace.WorkspaceFs for MagpieSettingsFs with fn kind(
  _self,
  _path,
  follow_symlink~,
) {
  let _ = follow_symlink
  @workspace.WorkspaceFileKind::File
}

///|
impl @workspace.WorkspaceFs for MagpieSettingsFs with fn read_file(self, path) {
  match self.files.get(path) {
    Some(content) => content
    None => raise @workspace.WorkspaceFsError::WorkspaceFsError("missing")
  }
}

///|
impl @workspace.WorkspaceFs for MagpieSettingsFs with fn write_file(
  self,
  path,
  content,
) {
  self.files[path] = content
}

///|
impl @workspace.WorkspaceFs for MagpieSettingsFs with fn write_file_atomic(
  self,
  path,
  content,
) {
  self.files[path] = content
}

///|
impl @workspace.WorkspaceFs for MagpieSettingsFs with fn remove(self, path) {
  ignore(self.files.remove(path))
}

///|
impl @workspace.WorkspaceFs for MagpieSettingsFs with fn rename(
  self,
  from,
  to,
  replace~,
) {
  let _ = replace
  match self.files.get(from) {
    Some(content) => {
      self.files[to] = content
      ignore(self.files.remove(from))
    }
    None => raise @workspace.WorkspaceFsError::WorkspaceFsError("rename failed")
  }
}

///|
impl @workspace.WorkspaceFs for MagpieSettingsFs with fn realpath(_self, path) {
  path
}

///|
impl @workspace.WorkspaceFs for MagpieSettingsFs with fn readdir(
  _self,
  _path,
  include_hidden~,
) {
  let _ = include_hidden
  []
}

///|
impl @workspace.WorkspaceFs for MagpieSettingsFs with fn walk(
  _self,
  _root,
  _callback,
) {

}

///|
impl @workspace.WorkspaceFs for MagpieSettingsFs with fn mkdir(
  _self,
  _path,
  recursive~,
) {
  let _ = recursive
}

///|
priv struct FakeMagpieStep {
  code : Int32
  body : String
}

///|
/// Scripted transport: queued GET bodies, recorded calls; nothing leaks.
struct FakeMagpieTransport {
  gets : Array[FakeMagpieStep]
  mut get_next : Int32
}

///|
fn FakeMagpieTransport::FakeMagpieTransport(
  gets~ : Array[FakeMagpieStep],
) -> FakeMagpieTransport {
  { gets, get_next: 0, }
}

///|
impl @magpie.MagpieTransport for FakeMagpieTransport with fn get(
  self : FakeMagpieTransport,
  url : String,
  headers : Map[String, String],
) -> (Int32, String) raise @magpie.MagpieGatewayError {
  ignore(url)
  ignore(headers)
  guard self.get_next < self.gets.length() else {
    raise @magpie.MagpieGatewayError::Offline("fake transport exhausted")
  }
  let step = self.gets[self.get_next]
  self.get_next += 1
  (step.code, step.body)
}

///|
impl @magpie.MagpieTransport for FakeMagpieTransport with fn post(
  _self : FakeMagpieTransport,
  url : String,
  headers~ : Map[String, String],
  body~ : String,
) -> (Int32, String) raise @magpie.MagpieGatewayError {
  ignore(url)
  ignore(headers)
  ignore(body)
  raise @magpie.MagpieGatewayError::Offline("fake transport: no POST")
}

///|
impl @magpie.MagpieTransport for FakeMagpieTransport with fn post_stream(
  _self : FakeMagpieTransport,
  url : String,
  headers~ : Map[String, String],
  body~ : String,
) -> (Int32, &@magpie.MagpieEventStream) raise @magpie.MagpieGatewayError {
  ignore(url)
  ignore(headers)
  ignore(body)
  raise @magpie.MagpieGatewayError::Offline("fake transport: no stream")
}

///|
/// A complete hello + catalog script: one effort-ladder model and one routing
/// group, the way the gateway reports them.
fn magpie_face_transport() -> FakeMagpieTransport {
  FakeMagpieTransport(gets=[
    { code: 200, body: "{\"name\":\"magpie\",\"version\":\"0.1.1224\"}", },
    {
      code: 200,
      body: "{\"data\":[{\"id\":\"anthropic/claude-native\",\"display_name\":\"Claude Native\",\"owned_by\":\"anthropic\",\"reasoning\":true,\"supported_reasoning_levels\":[{\"effort\":\"low\"},{\"effort\":\"high\"}],\"context_window\":200000,\"native_endpoints\":[\"/v1/messages\"],\"modalities\":{\"input\":[\"text\",\"image\"]}},{\"id\":\"group/fast\",\"display_name\":\"Fast Lane\",\"owned_by\":\"relay\",\"group\":true}]}",
    },
  ])
}

///|
fn magpie_face_settings(
  base_url~ : String,
  model~ : String,
  effort~ : String,
) -> MagpieHostSettings {
  {
    base_url: Some(base_url),
    enabled: true,
    gateway_key: None,
    model: Some(model),
    effort: Some(effort),
  }
}

///|
fn magpie_binding(
  settings : MagpieHostSettings,
  transport : &@magpie.MagpieTransport,
) -> MagpieBinding raise {
  bind_magpie_manager(settings, transport=Some(transport))
}

///|
async test "magpie settings: absent file and non-magpie manager resolve to none" {
  let fs = MagpieSettingsFs()
  let warns : Array[String] = []
  let none = read_magpie_host_settings(
    fs,
    home="/h",
    cred_store=@credentials.FileProviderCredentialStore(
      fs,
      @cetas_core.credentials_path("/h"),
    ),
    warn=fn(text : String) noraise { warns.push(text) },
  )
  assert_true(none is None)
  fs.files["/h/.cetas/settings.json"] = "{\"providers\":{}}"
  let providers = read_magpie_host_settings(
    fs,
    home="/h",
    cred_store=@credentials.FileProviderCredentialStore(
      fs,
      @cetas_core.credentials_path("/h"),
    ),
    warn=fn(text : String) noraise { warns.push(text) },
  )
  assert_true(providers is None)
  assert_eq(warns.length(), 0)
}

///|
async test "magpie settings: valid block parses seed and warns about gateway_key" {
  let fs = MagpieSettingsFs()
  fs.files["/h/.cetas/settings.json"] = "{\"model_manager\":\"magpie\",\"magpie\":{\"base_url\":\"https://gw.example\",\"enabled\":false,\"gateway_key\":\"leaked\"},\"model\":\"gw/m1\",\"reasoning_effort\":\"mid\"}"
  let warns : Array[String] = []
  let settings = read_magpie_host_settings(
    fs,
    home="/h",
    cred_store=@credentials.FileProviderCredentialStore(
      fs,
      @cetas_core.credentials_path("/h"),
    ),
    warn=fn(text : String) noraise { warns.push(text) },
  )
  let parsed = match settings {
    Some(parsed) => parsed
    None => fail("expected magpie settings")
  }
  assert_true(parsed.base_url is Some(_))
  assert_false(parsed.enabled)
  // A gateway_key inside settings.json is ignored and reported, never used.
  assert_true(parsed.gateway_key is None)
  assert_eq(warns.length(), 1)
  assert_true(warns[0].contains("gateway_key is ignored"))
  assert_true(parsed.model is Some(_))
  assert_true(parsed.effort is Some(_))
}

///|
async test "magpie settings: malformed shapes fail loudly" {
  let fs = MagpieSettingsFs()
  let cred_store = @credentials.FileProviderCredentialStore(
    fs,
    @cetas_core.credentials_path("/h"),
  )
  let loud : async (String) -> Unit noraise = fn(text : String) noraise {
    ignore(text)
  }
  let bad_json = async fn() raise @posoco.CompositionError {
    fs.files["/h/.cetas/settings.json"] = "{broken"
    ignore(read_magpie_host_settings(fs, home="/h", cred_store~, warn=loud))
  }
  try bad_json() catch {
    @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
      assert_true(detail.contains("not valid JSON"))
    _ => fail("expected ManifestSchemaError for malformed file")
  } noraise {
    _ => fail("expected malformed file to raise")
  }
  fs.files["/h/.cetas/settings.json"] = "{\"model_manager\":\"magpie\",\"magpie\":{\"base_url\":42}}"
  let bad_url = async fn() raise @posoco.CompositionError {
    ignore(read_magpie_host_settings(fs, home="/h", cred_store~, warn=loud))
  }
  try bad_url() catch {
    @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
      assert_true(detail.contains("base_url must be a string"))
    _ => fail("expected ManifestSchemaError for base_url shape")
  } noraise {
    _ => fail("expected base_url shape to raise")
  }
  fs.files["/h/.cetas/settings.json"] = "{\"model_manager\":\"magpie\",\"model\":42}"
  let bad_model = async fn() raise @posoco.CompositionError {
    ignore(read_magpie_host_settings(fs, home="/h", cred_store~, warn=loud))
  }
  try bad_model() catch {
    @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
      assert_true(detail.contains("settings.model must be a string"))
    _ => fail("expected ManifestSchemaError for model shape")
  } noraise {
    _ => fail("expected model shape to raise")
  }
}

///|
async test "magpie face: offline runtime keeps the seed and projects catalog slots" {
  let transport = magpie_face_transport()
  let binding = magpie_binding(
    magpie_face_settings(
      base_url="http://127.0.0.1:1",
      model="anthropic/claude-native",
      effort="high",
    ),
    transport,
  )
  let face : ModelManagerFace = Magpie(binding)
  let control = face.manager_control()
  assert_eq(control.manager_id(), "magpie")
  // Refresh populates the catalog; the seed selection survives it.
  try {
    let _ = binding.runtime.manager().refresh()
  } catch {
    _ => ()
  }
  assert_eq(face.manager_active_model_id(), "anthropic/claude-native")
  assert_true(face.manager_active_effort() is Some(_))
  let slots = face.manager_catalog_slots_json()
  assert_eq(slots.length(), 2)
  // Entries carry the fixed magpie provider group; the routing group keeps
  // its own display group.
  let first = match slots[0] {
    Json::Object(fields) => fields
    _ => fail("slot entry must be an object")
  }
  assert_true(first.get("provider") is Some(Json::String("magpie")))
  // The scripted entry advertises a ladder but no explicit default, so the
  // picker shows both levels with no fabricated default.
  assert_true(first.get("default_effort") is Some(Json::Null))
  assert_true(
    first.get("efforts")
    is Some(Json::Array([Json::String("low"), Json::String("high")])),
  )
  let second = match slots[1] {
    Json::Object(fields) => fields
    _ => fail("slot entry must be an object")
  }
  assert_true(second.get("group") is Some(Json::String("Routing Groups")))
  // The face joins the composition as the runtime extension; the port is the
  // runtime's own model port.
  assert_eq(face.manager_extension().manifest().id, "posoco_ext_magpie")
  assert_eq(face.manager_extension().manifest().models.length(), 1)
}

///|
async test "manager switch: runtime recomposes under magpie and back" {
  @async.with_task_group(group => {
    let fs_impl = @workspace.NativeWorkspaceFs()
    let fs : &@workspace.WorkspaceFs = fs_impl
    let home = @fs.tmpdir(prefix="cetas-console-magpie-home-")
    fs.mkdir(home + "/.cetas", recursive=true) catch {
      _ => ()
    }
    // The provider fixture mirrors the recipe probe: an authenticated
    // opencode provider plus a pre-seeded models.dev cache, so composition
    // never reaches for the network.
    fs.write_file(
      home + "/.cetas/settings.json",
      "{\"providers\":{\"opencode\":{\"api_key\":\"sk-fixture\"}}}",
    ) catch {
      _ => ()
    }
    fs.write_file(
      home + "/.cetas/models_dev.json",
      "{\"version\":1,\"providers\":{\"opencode\":{\"models\":{\"probe-model\":200000},\"fetched_at\":\"0\"}}}",
    ) catch {
      _ => ()
    }
    let cwd = @fs.tmpdir(prefix="cetas-console-magpie-ws-")
    let config = console_config(
      fs,
      home,
      "cetas-go-test",
      "cetas-go-test/0.1",
      native_ui=false,
      native_pi_enabled=false,
      permission_mode=@permission.PermissionMode::Yolo,
      herdr_presence=false,
    )
    let runtime = compose_console_runtime(config, cwd, group)
    let before = runtime.runtime_json()
    // Collect every outcome first: assertions run after the group drains, so
    // a failing test reports instead of hanging the task group. An error
    // outcome normalizes into the same object shape under "error".
    let outcome = async fn(choice : String) -> Json {
      match runtime.switch_model_manager(choice) {
        Ok(state) => state
        Err(message) =>
          Json::object(Map::from_array([("error", Json::string(message))]))
      }
    }
    let magpie_outcome = outcome("magpie")
    let back_outcome = outcome("providers")
    let bad_outcome = outcome("acme")
    runtime.shutdown_all()
    let session_before = json_string_field(before, key="session_id")
    let manager_before = json_string_field(before, key="model_manager")
    // The wire carries the settings vocabulary, not the control-plane owner id
    // status ops are tagged with: hosts mark the active picker choice by it.
    assert_eq(manager_before, "providers")
    assert_true(
      json_string_field(magpie_outcome, key="model_manager") == "magpie",
    )
    assert_true(
      json_string_field(back_outcome, key="model_manager") == "providers",
    )
    assert_eq(json_string_field(back_outcome, key="session_id"), session_before)
    assert_true(json_string_field(bad_outcome, key="error") != "")
  })
}

///|
/// A manager switch must resolve the providers selection again. The platform
/// owns the providers router and its active slot is resolved at build time, so
/// a reused platform composes the switched-to manager over the selection the
/// previous manager left in `settings.json`.
async test "manager switch: providers resumes its own persisted model" {
  @async.with_task_group(group => {
    let fs_impl = @workspace.NativeWorkspaceFs()
    let fs : &@workspace.WorkspaceFs = fs_impl
    let home = @fs.tmpdir(prefix="cetas-console-manager-model-home-")
    fs.mkdir(home + "/.cetas", recursive=true) catch {
      _ => ()
    }
    // Boots under magpie, so the top-level `model` is a gateway id the
    // providers catalog does not know; the providers stash is the slot a
    // switch back must restore.
    fs.write_file(
      home + "/.cetas/settings.json",
      "{\"providers\":{\"opencode\":{\"api_key\":\"sk-fixture\"}},\"model_manager\":\"magpie\",\"model\":\"group/magpie-a\",\"manager_selections\":{\"magpie\":{\"model\":\"group/magpie-a\",\"reasoning_effort\":\"low\"},\"providers\":{\"model\":\"opencode/gpt-5.1-codex\",\"reasoning_effort\":\"high\"}}}",
    ) catch {
      _ => ()
    }
    let cwd = @fs.tmpdir(prefix="cetas-console-manager-model-ws-")
    let config = console_config(
      fs,
      home,
      "cetas-go-test",
      "cetas-go-test/0.1",
      native_ui=false,
      native_pi_enabled=false,
      permission_mode=@permission.PermissionMode::Yolo,
      herdr_presence=false,
    )
    let runtime = compose_console_runtime(config, cwd, group)
    let switch_to_providers = async fn() -> Json {
      match runtime.switch_model_manager("providers") {
        Ok(state) => state
        Err(message) =>
          Json::object(Map::from_array([("error", Json::string(message))]))
      }
    }
    let outcome = switch_to_providers()
    let switched = runtime.runtime_json()
    runtime.shutdown_all()
    assert_eq(json_string_field(outcome, key="error"), "")
    assert_eq(
      json_string_field(switched, key="model"),
      "opencode/gpt-5.1-codex",
    )
  })
}

///|
/// Read one string field from a JSON object; anything else is empty.
fn json_string_field(value : Json, key~ : String) -> String {
  match value {
    Json::Object(fields) =>
      match fields.get(key) {
        Some(Json::String(text)) => text
        _ => ""
      }
    _ => ""
  }
}

// ------------------------------------------------------------ gateway login

///|
async test "magpie origin: contract matrix matches the cetas-js validator" {
  let ok = fn(url : String) -> String {
    validate_magpie_origin(url) catch {
      _ => ""
    }
  }
  assert_eq(ok("https://gw.example"), "https://gw.example")
  assert_eq(ok("https://gw.example:8443"), "https://gw.example:8443")
  // The scheme's default port is stripped, the way URL.origin does.
  assert_eq(ok("https://gw.example:443"), "https://gw.example")
  assert_eq(ok("http://127.0.0.1:3425"), "http://127.0.0.1:3425")
  assert_eq(ok("http://localhost"), "http://localhost")
  assert_eq(ok("http://LOCALHOST:80"), "http://localhost")
  assert_eq(ok("http://[::1]:9000"), "http://[::1]:9000")
  // HTTP non-loopback, deep paths, userinfo, query, wrong scheme: all loud.
  assert_eq(ok("http://gw.example"), "")
  assert_eq(ok("https://gw.example/v1"), "")
  assert_eq(ok("https://user@gw.example"), "")
  assert_eq(ok("https://gw.example?key=1"), "")
  assert_eq(ok("ftp://gw.example"), "")
  assert_eq(ok("gw.example"), "")
  assert_eq(ok("https://gw.example:abc"), "")
}

///|
async test "magpie address: merge and write enable the gateway section" {
  let fs = MagpieSettingsFs()
  fs.files["/h/.cetas/settings.json"] = "{\"model_manager\":\"providers\",\"providers\":{}}"
  write_magpie_address(fs, home="/h", origin="https://gw.example")
  let written = @json.parse(fs.files["/h/.cetas/settings.json"]) catch {
    _ => fail("written settings must parse")
  }
  let fields = match written {
    Json::Object(inner) => inner
    _ => fail("written settings must be an object")
  }
  assert_true(fields.get("model_manager") is Some(Json::String("providers")))
  let magpie = match fields.get("magpie") {
    Some(Json::Object(inner)) => inner
    _ => fail("magpie section must be an object")
  }
  assert_true(
    magpie.get("base_url") is Some(Json::String("https://gw.example")),
  )
  assert_true(magpie.get("enabled") is Some(Json::True))
}
