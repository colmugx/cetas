///|
/// White-box tests for the model-list disk cache: permissive read rules,
/// catalog projection shape, merge round-trip, and write behavior on the
/// in-memory WorkspaceFs shared with active_model_wbtest.mbt (no real IO,
/// runs on every target).

///|
/// A slot carrying every projection-relevant field, over the scripted port.
fn cache_slot(
  model_id : String,
  thinking_efforts? : Array[String] = [],
  default_effort? : String? = None,
  context_window? : Int? = None,
) -> @llm.ModelSlot {
  @llm.ModelSlot::ModelSlot(
    id="test/" + model_id,
    label=model_id,
    provider_id="test",
    model_id~,
    port=@posoco.ScriptedModel([]),
    thinking_efforts~,
    default_effort~,
    context_window~,
  )
}

// -------------------------------------------------------------------- read

///|
async test "read: a missing cache file is a normal empty state" {
  match read_model_list_cache(FakeFs(), home="/cetas-home") {
    Ok(entries) => assert_true(entries.length() == 0)
    Err(message) => fail("missing file must be Ok(empty), got: " + message)
  }
}

///|
async test "read: malformed or failing reads degrade to Err, never raise" {
  let malformed = FakeFs()
  malformed.files["/cetas-home/.cetas/model_lists.json"] = "{not json"
  match read_model_list_cache(malformed, home="/cetas-home") {
    Ok(_) => fail("malformed JSON must be Err")
    Err(message) => assert_true(message.contains("not valid JSON"))
  }
  let failing = FakeFs()
  failing.files["/cetas-home/.cetas/model_lists.json"] = "{}"
  failing.fail_ops["read_file"] = true
  match read_model_list_cache(failing, home="/cetas-home") {
    Ok(_) => fail("read failure must be Err")
    Err(message) => assert_true(message.contains("read failed"))
  }
}

///|
async test "read: a non-object root parses to an empty cache" {
  let fs = FakeFs()
  fs.files["/cetas-home/.cetas/model_lists.json"] = "[1,2]"
  match read_model_list_cache(fs, home="/cetas-home") {
    Ok(entries) => assert_true(entries.length() == 0)
    Err(message) => fail("non-object root must be Ok(empty), got: " + message)
  }
}

// -------------------------------------------------------------- projection

///|
test "projection: catalog slots round into ordered records" {
  let catalog = tk_catalog([
    cache_slot("model-a"),
    cache_slot(
      "model-b",
      thinking_efforts=["off", "high"],
      default_effort=Some("high"),
      context_window=Some(131072),
    ),
  ])
  let records = catalog_model_records(catalog)
  let items = match records {
    Json::Array(items) => items
    _ => fail("projection must be an array")
  }
  assert_eq(items.length(), 2)
  let first = match items[0] {
    Json::Object(fields) => fields
    _ => fail("records must be objects")
  }
  assert_eq(first.get("model_id"), Some(Json::string("model-a")))
  assert_eq(first.get("thinking_efforts"), Some(Json::array([])))
  assert_eq(first.get("default_effort"), Some(Json::null()))
  assert_eq(first.get("context_window"), Some(Json::null()))
  let second = match items[1] {
    Json::Object(fields) => fields
    _ => fail("records must be objects")
  }
  assert_eq(second.get("model_id"), Some(Json::string("model-b")))
  assert_eq(
    second.get("thinking_efforts"),
    Some(Json::array([Json::string("off"), Json::string("high")])),
  )
  assert_eq(second.get("default_effort"), Some(Json::string("high")))
  assert_eq(second.get("context_window"), Some(Json::number(131072.0)))
}

// ------------------------------------------------------- merge and write

///|
test "merge: replaces one provider and preserves unknown keys" {
  let existing = @json.parse(
    "{\"opencode\":[{\"model_id\":\"old\"}],\"deepseek\":[],\"unrelated\":42}",
  ) catch {
    _ => fail("fixture must parse")
  }
  let merged = merge_model_list_cache(
    existing,
    "opencode",
    Json::array([
      Json::object(Map::from_array([("model_id", Json::string("new"))])),
    ]),
  )
  let fields = match merged {
    Json::Object(fields) => fields
    _ => fail("merged root must be an object")
  }
  match fields.get("opencode") {
    Some(Json::Array(items)) =>
      match items[0] {
        Json::Object(record) =>
          assert_eq(record.get("model_id"), Some(Json::string("new")))
        _ => fail("replacement record must be an object")
      }
    _ => fail("opencode key must stay an array")
  }
  assert_true(fields.contains("deepseek"))
  assert_eq(fields.get("unrelated"), Some(Json::number(42.0)))
}

///|
async test "write: round-trips records and self-heals a malformed root" {
  let fs = FakeFs()
  write_model_list_cache(
    fs,
    home="/cetas-home",
    "opencode",
    Json::array([
      Json::object(Map::from_array([("model_id", Json::string("m1"))])),
    ]),
  ) catch {
    _ => fail("first write must succeed on a fresh fs")
  }
  write_model_list_cache(
    fs,
    home="/cetas-home",
    "deepseek",
    Json::array([
      Json::object(Map::from_array([("model_id", Json::string("m2"))])),
    ]),
  ) catch {
    _ => fail("second write must succeed")
  }
  match read_model_list_cache(fs, home="/cetas-home") {
    Ok(entries) => {
      assert_eq(entries.length(), 2)
      assert_true(entries.contains("opencode"))
      assert_true(entries.contains("deepseek"))
    }
    Err(message) => fail("round-trip read failed: " + message)
  }
  // A corrupted root is replaced, not preserved: the cache is derived data.
  fs.files["/cetas-home/.cetas/model_lists.json"] = "nonsense"
  write_model_list_cache(fs, home="/cetas-home", "opencode", Json::array([])) catch {
    _ => fail("write over a malformed root must self-heal")
  }
  match read_model_list_cache(fs, home="/cetas-home") {
    Ok(entries) => assert_eq(entries.length(), 1)
    Err(message) => fail("self-healed read failed: " + message)
  }
}

///|
async test "write: a failing atomic write raises a typed composition error" {
  let fs = FakeFs()
  fs.fail_ops["write_file_atomic"] = true
  let result = Ok(
    write_model_list_cache(fs, home="/cetas-home", "opencode", Json::array([])),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("write failed"))
    _ => fail("atomic write failure must surface as ManifestSchemaError")
  }
}

// -------------------------------------------------------------- threading

///|
/// A factory that records whether the source carried cached records: build
/// answers through the records' model ids so the threading is observable.
struct ProbeFactory {
  seen_cached : Array[Bool]
}

///|
impl @llm.ProviderFactory for ProbeFactory with fn provider_id(_self) {
  "probe"
}

///|
impl @llm.ProviderFactory for ProbeFactory with fn credential_id(_self) {
  "probe"
}

///|
impl @llm.ProviderFactory for ProbeFactory with fn build(self, source) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  let carried = match source.cached_models {
    Some(Json::Array(items)) if items.length() > 0 => true
    _ => false
  }
  self.seen_cached.push(carried)
  let slots : Array[@llm.ModelSlot] = []
  if carried {
    slots.push(cache_slot("from-cache"))
  } else {
    slots.push(cache_slot("static"))
  }
  @llm.ProviderBuildResult::Ready(tk_catalog(slots))
}

///|
test "build_provider_catalog threads cached records into the source" {
  let probe = ProbeFactory::{ seen_cached: [] }
  let factory : &@llm.ProviderFactory = probe
  let snapshot = ProviderCredentialSnapshot::ProviderCredentialSnapshot()
  let uncached = build_provider_catalog(factory, snapshot) catch {
    _ => fail("uncached build must succeed")
  }
  match uncached {
    Some(catalog) => assert_eq(catalog.slots()[0].model_id, "static")
    None => fail("uncached build must be Ready")
  }
  let cached = build_provider_catalog(
    factory,
    snapshot,
    cached_models=Some(
      Json::array([
        Json::object(Map::from_array([("model_id", Json::string("m1"))])),
      ]),
    ),
  ) catch {
    _ => fail("cached build must succeed")
  }
  match cached {
    Some(catalog) => assert_eq(catalog.slots()[0].model_id, "from-cache")
    None => fail("cached build must be Ready")
  }
  assert_eq(probe.seen_cached, [false, true])
}
