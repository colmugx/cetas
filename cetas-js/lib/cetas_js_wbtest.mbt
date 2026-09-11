///|
test "JsUiPort wire encodes a structured render event" {
  let raw = ui_render_event_to_json({
    slot: @port.UiSlot::Status,
    key: "goal.progress",
    title: Some("Goal"),
    body: @port.UiBody::Progress(0.5),
    ttl_ms: Some(1000),
  })
  let json = @json.parse(raw)
  match json {
    Json::Object(event) => {
      assert_eq(event["type"], Json::string("ui_render"))
      match event["render"] {
        Json::Object(render) => {
          assert_eq(render["key"], Json::string("goal.progress"))
          assert_eq(render["ttl_ms"], Json::number(1000.0))
        }
        _ => fail("render must be an object")
      }
    }
    _ => fail("event must be an object")
  }
}

///|
test "JsUiPort wire encodes entries bodies with optional color roles" {
  let raw = ui_render_event_to_json({
    slot: @port.UiSlot::Status,
    key: "statusbar",
    title: None,
    body: @port.UiBody::Entries([
      { key: "model", value: "deepseek-v4-pro", color: Some("accent"), },
      { key: "session", value: "s1", color: None, },
    ]),
    ttl_ms: None,
  })
  let json = @json.parse(raw)
  match json {
    Json::Object(event) =>
      match event["render"] {
        Json::Object(render) =>
          match render["body"] {
            Json::Object(body) => {
              assert_eq(body["type"], Json::string("entries"))
              match body["entries"] {
                Json::Array(entries) => {
                  assert_eq(entries.length(), 2)
                  match entries[0] {
                    Json::Object(first) => {
                      assert_eq(first["key"], Json::string("model"))
                      assert_eq(first["value"], Json::string("deepseek-v4-pro"))
                      assert_eq(first["color"], Json::string("accent"))
                    }
                    _ => fail("first entry must be an object")
                  }
                  match entries[1] {
                    Json::Object(second) => {
                      assert_eq(second["key"], Json::string("session"))
                      assert_eq(second["value"], Json::string("s1"))
                      // Absent color stays absent on the wire.
                      assert_eq(second.contains("color"), false)
                    }
                    _ => fail("second entry must be an object")
                  }
                }
                _ => fail("entries must be an array")
              }
            }
            _ => fail("body must be an object")
          }
        _ => fail("render must be an object")
      }
    _ => fail("event must be an object")
  }
}

///|
test "JsUiPort wire decodes a correlated input response" {
  let response = decode_ui_response_event(
    "{\"type\":\"ui_response\",\"request_id\":\"ui-7\",\"response\":{\"type\":\"text\",\"text\":\"answer\"}}",
    "ui-7",
    @port.UiRequest::Input(prompt="Question", default=None),
  )
  match response {
    @port.UiResponse::Text(value) => assert_eq(value, "answer")
    _ => fail("expected text response")
  }
}

///|
test "JsUiPort wire rejects a response for another request" {
  try
    ignore(
      decode_ui_response_event(
        "{\"type\":\"ui_response\",\"request_id\":\"ui-8\",\"response\":{\"type\":\"yes\"}}",
        "ui-7",
        @port.UiRequest::Confirm(prompt="Continue?"),
      ),
    )
  catch {
    @error.UiError::InvalidRequest(detail=message) =>
      assert_eq(message, "ui_response.request_id does not match")
    _ => fail("expected UiError::HostError")
  } noraise {
    _ => fail("expected mismatched request id to fail")
  }
}

///|
test "model refresh selector validates provider ids and deduplicates requests" {
  match parse_refresh_provider_ids("") {
    None => ()
    Some(_) => fail("an empty selector must refresh all providers")
  }
  match parse_refresh_provider_ids("[\"kimi\",\"kimi\"]") {
    Some(ids) => {
      assert_eq(ids.length(), 1)
      assert_eq(ids[0], "kimi")
    }
    None => fail("an explicit selector must remain provider-scoped")
  }
  let unknown = Ok(parse_refresh_provider_ids("[\"unknown\"]")) catch {
    err => Err(err)
  }
  match unknown {
    Err(@posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~)) => {
      ignore(manifest_id)
      assert_true(detail.contains("no registered provider extension"))
    }
    _ => fail("unknown refresh providers must fail at the composition boundary")
  }
}

///|
test "CetasJsConfig empty sessions_dir falls back to the per-project bucket" {
  let config = CetasJsConfig::CetasJsConfig(
    "/work", 0, "/home/u", "workspace_write", "", "",
  )
  assert_eq(
    config.sessions_dir,
    @fs_session.project_sessions_dir("/home/u", "/work"),
  )
  // The fallback is a `session_<slug>_<hash>` bucket, not the flat root.
  assert_true(config.sessions_dir.contains("/.cetas/sessions/session_"))
}

///|
test "CetasJsConfig keeps an explicit sessions_dir" {
  let config = CetasJsConfig::CetasJsConfig(
    "/work", 0, "/home/u", "yolo", "/home/u/.cetas/sessions/--work--", "",
  )
  assert_eq(config.sessions_dir, "/home/u/.cetas/sessions/--work--")
}

///|
test "cetas_js_sessions_dir agrees with the fs-session project layout" {
  assert_eq(
    cetas_js_sessions_dir("/home/u", "/work"),
    @fs_session.project_sessions_dir("/home/u", "/work"),
  )
  // Sibling paths that a slug alone would collide get distinct buckets.
  assert_true(
    cetas_js_sessions_dir("/home/u", "/a/b_c") !=
    cetas_js_sessions_dir("/home/u", "/a/b/c"),
  )
}

///|
async test "cetas_js_session_titles lists a missing directory as empty" {
  let missing = "/tmp/cetas-js-titles-missing-nonexistent"
  let raw = cetas_js_session_titles(missing).wait()
  assert_eq(raw, "[]")
}

///|
/// The agent-lifetime nmem group wiring, exercised at the seam the bridge
/// owns: composition publishes while the background task is still a group
/// child, the owner stays parked (group open) past composition, and the
/// shutdown order — stop the flusher, then release the close queue — retires
/// the whole session scope. This is what keeps the nmem attach-gate satisfied
/// in cetas-bun: boot config resolution, inbound injection, and drains all
/// key off `attached`, which only a group-backed `attach` sets.
async test "agent group session parks past composition and retires on close" {
  let ready : @aqueue.Queue[Result[Int, Error]] = Queue(kind=Unbounded)
  let close : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  let flusher_started = Ref::{ val: false, }
  let flusher_stopped = Ref::{ val: false, }
  let session_retired = Ref::{ val: false, }
  @async.with_timeout(10_000, async fn() {
    @async.with_task_group(async fn(outer) {
      outer.spawn_bg(async fn() {
        run_agent_group_session(ready~, close~, compose=fn(group) {
          // Stand-in for NowledgeMem::attach: a waited background loop that
          // only an engine stop can end.
          group.spawn_bg(async fn() {
            flusher_started.val = true
            while !flusher_stopped.val {
              @async.sleep(5)
            }
          })
          42
        })
        session_retired.val = true
      })
      match ready.get() {
        Ok(handle) => assert_eq(handle, 42)
        Err(_) => fail("composition must publish, not fail")
      }
      // The owner parked on the close queue: the group is still open even
      // though compose already returned.
      assert_false(session_retired.val)
      // Real shutdown order: engine stop first, close signal second.
      flusher_stopped.val = true
      close.put(())
    })
    assert_true(flusher_started.val)
    assert_true(session_retired.val)
  })
}

///|
test "turn_event_to_json maps ToolCallDelta onto tool_args_delta" {
  let event : @posoco.TurnEvent = StreamChunkReceived(
    chunk=ToolCallDelta(
      index=1,
      id=Some("call_9"),
      name=Some("write"),
      arguments_delta=Some("{\"path\""),
    ),
  )
  let json = @json.parse(turn_event_to_json(event).stringify())
  match json {
    Json::Object(fields) => {
      assert_eq(fields["type"], Json::string("tool_args_delta"))
      assert_eq(fields["index"], Json::number(1.0))
      assert_eq(fields["id"], Json::string("call_9"))
      assert_eq(fields["name"], Json::string("write"))
      assert_eq(fields["delta"], Json::string("{\"path\""))
    }
    _ => fail("event must be an object")
  }
}

///|
test "turn_event_to_json carries only Some fields on later fragments" {
  let event : @posoco.TurnEvent = StreamChunkReceived(
    chunk=ToolCallDelta(
      index=0,
      id=None,
      name=None,
      arguments_delta=Some("abc"),
    ),
  )
  let json = @json.parse(turn_event_to_json(event).stringify())
  match json {
    Json::Object(fields) => {
      assert_eq(fields["type"], Json::string("tool_args_delta"))
      assert_eq(fields["index"], Json::number(0.0))
      assert_eq(fields.get("id"), None)
      assert_eq(fields.get("name"), None)
      assert_eq(fields["delta"], Json::string("abc"))
    }
    _ => fail("event must be an object")
  }
}

///|
test "turn_event_to_json skips StreamChunksDropped (null sentinel)" {
  let event : @posoco.TurnEvent = StreamChunksDropped(count=3)
  match turn_event_to_json(event) {
    Json::Null => ()
    _ => fail("expected Json null skip sentinel")
  }
}

///|
/// Isolated home for the live-refresh tests: a fresh /tmp directory per call
/// so `settings.json` is absent (unconfigured) and `model_lists.json` writes
/// never touch the developer's real `~/.cetas`. Nothing process-global is
/// touched: fixtures are local structs, and the runtime/config are per-test.
async fn live_refresh_test_home(tag : String) -> String {
  let unique = js_random_uuid()
  let home = if unique.length() > 0 {
    "/tmp/cetas-js-live-refresh-" + tag + "-" + unique
  } else {
    "/tmp/cetas-js-live-refresh-" + tag
  }
  let fs = @workspace.JsWorkspaceFs()
  fs.mkdir(home + "/.cetas", recursive=true) catch {
    _ => ()
  }
  home
}

///|
/// Best-effort removal of a live-refresh test home so the test leaves no
/// /tmp state behind.
async fn live_refresh_test_cleanup(home : String) -> Unit {
  let fs = @workspace.JsWorkspaceFs()
  fs.remove(home + "/.cetas/model_lists.json") catch {
    _ => ()
  }
  fs.remove(home + "/.cetas/kimi_device_id") catch {
    _ => ()
  }
  fs.remove(home + "/.cetas") catch {
    _ => ()
  }
  fs.remove(home) catch {
    _ => ()
  }
}

///|
fn live_refresh_test_slot(
  provider_id : String,
  id : String,
  label : String,
) -> @llm.ModelSlot {
  @llm.ModelSlot::ModelSlot(
    id~,
    label~,
    provider_id~,
    model_id=id,
    port=@posoco.ScriptedModel([]),
  )
}

///|
fn live_refresh_test_catalog(
  provider_id : String,
  ids : Array[String],
) -> @llm.ProviderModelCatalog raise {
  let slots : Array[@llm.ModelSlot] = []
  for id in ids {
    slots.push(live_refresh_test_slot(provider_id, id, id))
  }
  @llm.ProviderModelCatalog::ProviderModelCatalog(provider_id~, slots~)
}

///|
/// Refreshable-provider fixture: serves a fixed catalog; `fail_refresh`
/// makes the refresh raise instead. Implements the static factory trait too
/// so the live loop can iterate it in the composition factory list.
priv struct FakeLiveRefreshFactory {
  fixed_id : String
  catalog : @llm.ProviderModelCatalog
  fail_refresh : Bool
}

///|
impl @llm.ProviderFactory for FakeLiveRefreshFactory with fn provider_id(
  self : FakeLiveRefreshFactory,
) -> String {
  self.fixed_id
}

///|
impl @llm.ProviderFactory for FakeLiveRefreshFactory with fn credential_id(
  self : FakeLiveRefreshFactory,
) -> String {
  self.fixed_id
}

///|
impl @llm.ProviderFactory for FakeLiveRefreshFactory with fn build(
  self : FakeLiveRefreshFactory,
  _source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  @llm.ProviderBuildResult::Ready(self.catalog)
}

///|
impl @llm.RefreshableProviderFactory for FakeLiveRefreshFactory with fn provider_id(
  self : FakeLiveRefreshFactory,
) -> String {
  self.fixed_id
}

///|
impl @llm.RefreshableProviderFactory for FakeLiveRefreshFactory with fn refresh(
  self : FakeLiveRefreshFactory,
  _source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  if self.fail_refresh {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="cetas-js.live-refresh-fixture",
      detail="fixture refresh boom",
    )
  }
  @llm.ProviderBuildResult::Ready(self.catalog)
}

///|
/// Static-only fixture: a registered provider with no live-refresh seam.
priv struct FakeLivePlainFactory {
  fixed_id : String
}

///|
impl @llm.ProviderFactory for FakeLivePlainFactory with fn provider_id(
  self : FakeLivePlainFactory,
) -> String {
  self.fixed_id
}

///|
impl @llm.ProviderFactory for FakeLivePlainFactory with fn credential_id(
  self : FakeLivePlainFactory,
) -> String {
  self.fixed_id
}

///|
impl @llm.ProviderFactory for FakeLivePlainFactory with fn build(
  _self : FakeLivePlainFactory,
  _source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  @llm.ProviderBuildResult::Unconfigured
}

///|
/// Parse a live-refresh summary into its result entries; the tests fail
/// loudly when the envelope does not match the contract shape.
fn live_refresh_summary_entries(summary : String) -> Array[Json] raise {
  let entries : Array[Json] = []
  match @json.parse(summary) {
    Json::Object(fields) =>
      match fields["results"] {
        Json::Array(results) =>
          for value in results {
            entries.push(value)
          }
        _ => fail("summary.results must be an array")
      }
    _ => fail("summary must be a JSON object")
  }
  entries
}

///|
fn live_refresh_entry_field(entry : Json, key : String) -> Json raise {
  match entry {
    Json::Object(fields) =>
      match fields.get(key) {
        Some(value) => value
        None => fail("live-refresh entry is missing key: " + key)
      }
    _ => fail("live-refresh entry must be a JSON object")
  }
}

///|
async test "live refresh swaps the composed router and persists the cache" {
  let home = live_refresh_test_home("success")
  let old_catalog = live_refresh_test_catalog("liveprov", [
    "liveprov/old-a", "liveprov/old-b",
  ])
  let new_catalog = live_refresh_test_catalog("liveprov", [
    "liveprov/new-a", "liveprov/new-b",
  ])
  let router = @llm.RouterModelPort::from_catalogs([old_catalog])
  let fixture = FakeLiveRefreshFactory::{
    fixed_id: "liveprov",
    catalog: new_catalog,
    fail_refresh: false,
  }
  let refreshable : &@llm.RefreshableProviderFactory = fixture
  let plain : &@llm.ProviderFactory = fixture
  let runtime = CetasJsRuntime::CetasJsRuntime(
    CetasJsConfig::CetasJsConfig(home, 0, home, "workspace_write", "", ""),
  )
  // Pre-seed the process cache with the OLD catalog and a composed router.
  runtime.catalog_cache["liveprov"] = old_catalog
  runtime.live_router = Some(router)
  assert_true(router.list_slot_ids().contains("liveprov/old-a"))
  let summary = refresh_model_lists_live_with(
    runtime,
    [plain],
    [refreshable],
    @cetas_core.ProviderCredentialSnapshot::ProviderCredentialSnapshot(),
    Some(["liveprov"]),
  )
  let entries = live_refresh_summary_entries(summary)
  assert_eq(entries.length(), 1)
  assert_eq(
    live_refresh_entry_field(entries[0], "provider"),
    Json::string("liveprov"),
  )
  assert_eq(
    live_refresh_entry_field(entries[0], "status"),
    Json::string("refreshed"),
  )
  assert_eq(live_refresh_entry_field(entries[0], "slots"), Json::number(2.0))
  live_refresh_entry_absent(entries[0], "reason")
  // Process cache now holds the refreshed catalog.
  match runtime.catalog_cache.get("liveprov") {
    Some(catalog) => assert_eq(catalog.slots()[0].id, "liveprov/new-a")
    None => fail("live refresh must update the process cache")
  }
  // The composed router was hot-swapped in place.
  let ids = router.list_slot_ids()
  assert_eq(ids.length(), 2)
  assert_eq(ids[0], "liveprov/new-a")
  assert_eq(ids[1], "liveprov/new-b")
  // The disk cache was persisted with the refreshed records.
  match
    @workspace.read_file_result(
      @workspace.JsWorkspaceFs(),
      home + "/.cetas/model_lists.json",
    ) {
    Content(text) => {
      let record = match @json.parse(text) {
        Json::Object(fields) =>
          match fields["liveprov"] {
            Json::Array(records) => {
              assert_eq(records.length(), 2)
              records[0]
            }
            _ => fail("liveprov cache records must be an array")
          }
        _ => fail("model cache file must hold an object")
      }
      match record {
        Json::Object(fields) =>
          assert_eq(fields["model_id"], Json::string("liveprov/new-a"))
        _ => fail("cache record must be an object")
      }
    }
    _ => fail("live refresh must persist the disk cache")
  }
  live_refresh_test_cleanup(home)
}

///|
/// Live-refresh entries carry `reason` only when there is something to
/// explain; this asserts the key is absent.
fn live_refresh_entry_absent(entry : Json, key : String) -> Unit raise {
  match entry {
    Json::Object(fields) =>
      match fields.get(key) {
        None => ()
        Some(_) => fail("live-refresh entry must not carry key: " + key)
      }
    _ => fail("live-refresh entry must be a JSON object")
  }
}

///|
async test "live refresh failure keeps the stale catalog and records an issue" {
  let home = live_refresh_test_home("failure")
  let old_catalog = live_refresh_test_catalog("liveprov", ["liveprov/old-a"])
  let new_catalog = live_refresh_test_catalog("liveprov", ["liveprov/new-a"])
  let router = @llm.RouterModelPort::from_catalogs([old_catalog])
  let fixture = FakeLiveRefreshFactory::{
    fixed_id: "liveprov",
    catalog: new_catalog,
    fail_refresh: true,
  }
  let refreshable : &@llm.RefreshableProviderFactory = fixture
  let plain : &@llm.ProviderFactory = fixture
  let runtime = CetasJsRuntime::CetasJsRuntime(
    CetasJsConfig::CetasJsConfig(home, 0, home, "workspace_write", "", ""),
  )
  runtime.catalog_cache["liveprov"] = old_catalog
  runtime.live_router = Some(router)
  let summary = refresh_model_lists_live_with(
    runtime,
    [plain],
    [refreshable],
    @cetas_core.ProviderCredentialSnapshot::ProviderCredentialSnapshot(),
    Some(["liveprov"]),
  )
  let entries = live_refresh_summary_entries(summary)
  assert_eq(entries.length(), 1)
  assert_eq(
    live_refresh_entry_field(entries[0], "status"),
    Json::string("failed"),
  )
  match live_refresh_entry_field(entries[0], "reason") {
    Json::String(reason) => assert_true(reason.contains("fixture refresh boom"))
    _ => fail("failed entry must carry the failure reason")
  }
  // The stale cache entry survives — no eviction on the live path.
  match runtime.catalog_cache.get("liveprov") {
    Some(catalog) => assert_eq(catalog.slots()[0].id, "liveprov/old-a")
    None => fail("live refresh failure must not evict the cached catalog")
  }
  // The composed router keeps its stale slots too.
  let ids = router.list_slot_ids()
  assert_eq(ids.length(), 1)
  assert_eq(ids[0], "liveprov/old-a")
  // A catalog_issues warning is recorded for describe_setup.
  assert_eq(runtime.catalog_issues.length(), 1)
  assert_eq(runtime.catalog_issues[0].provider_id, "liveprov")
  assert_true(runtime.catalog_issues[0].detail.contains("fixture refresh boom"))
  // A failed refresh writes nothing to the disk cache.
  match
    @workspace.read_file_result(
      @workspace.JsWorkspaceFs(),
      home + "/.cetas/model_lists.json",
    ) {
    Missing => ()
    _ => fail("failed refresh must not persist the disk cache")
  }
  live_refresh_test_cleanup(home)
}

///|
async test "live refresh without a composed agent skips the swap" {
  let home = live_refresh_test_home("no-agent")
  let old_catalog = live_refresh_test_catalog("liveprov", ["liveprov/old-a"])
  let new_catalog = live_refresh_test_catalog("liveprov", [
    "liveprov/new-a", "liveprov/new-b",
  ])
  let fixture = FakeLiveRefreshFactory::{
    fixed_id: "liveprov",
    catalog: new_catalog,
    fail_refresh: false,
  }
  let refreshable : &@llm.RefreshableProviderFactory = fixture
  let plain : &@llm.ProviderFactory = fixture
  let runtime = CetasJsRuntime::CetasJsRuntime(
    CetasJsConfig::CetasJsConfig(home, 0, home, "workspace_write", "", ""),
  )
  runtime.catalog_cache["liveprov"] = old_catalog
  runtime.live_router = None
  let summary = refresh_model_lists_live_with(
    runtime,
    [plain],
    [refreshable],
    @cetas_core.ProviderCredentialSnapshot::ProviderCredentialSnapshot(),
    Some(["liveprov"]),
  )
  let entries = live_refresh_summary_entries(summary)
  assert_eq(entries.length(), 1)
  assert_eq(
    live_refresh_entry_field(entries[0], "status"),
    Json::string("refreshed"),
  )
  live_refresh_entry_absent(entries[0], "reason")
  match runtime.catalog_cache.get("liveprov") {
    Some(catalog) => assert_eq(catalog.slots().length(), 2)
    None => fail("live refresh must update the process cache")
  }
  live_refresh_test_cleanup(home)
}

///|
async test "live refresh selector refreshes all, and silently skips not-refreshable picks" {
  let home = live_refresh_test_home("selector")
  let live_catalog = live_refresh_test_catalog("liveprov", ["liveprov/a"])
  let live_fixture = FakeLiveRefreshFactory::{
    fixed_id: "liveprov",
    catalog: live_catalog,
    fail_refresh: false,
  }
  let live_refreshable : &@llm.RefreshableProviderFactory = live_fixture
  let live_plain : &@llm.ProviderFactory = live_fixture
  let plain_fixture = FakeLivePlainFactory::{ fixed_id: "plainprov", }
  let plain : &@llm.ProviderFactory = plain_fixture
  let snapshot = @cetas_core.ProviderCredentialSnapshot::ProviderCredentialSnapshot()
  let make_runtime = fn() -> CetasJsRuntime {
    CetasJsRuntime::CetasJsRuntime(
      CetasJsConfig::CetasJsConfig(home, 0, home, "workspace_write", "", ""),
    )
  }
  // "" = every refreshable provider; the non-refreshable one stays out.
  let summary_all = refresh_model_lists_live_with(
    make_runtime(),
    [live_plain, plain],
    [live_refreshable],
    snapshot,
    None,
  )
  let entries_all = live_refresh_summary_entries(summary_all)
  assert_eq(entries_all.length(), 1)
  assert_eq(
    live_refresh_entry_field(entries_all[0], "provider"),
    Json::string("liveprov"),
  )
  // An explicit pick of a provider without a refresh seam is skipped
  // silently: nothing in the summary, nothing in catalog_issues.
  let runtime_plain = make_runtime()
  let summary_plain = refresh_model_lists_live_with(
    runtime_plain,
    [live_plain, plain],
    [live_refreshable],
    snapshot,
    Some(["plainprov"]),
  )
  assert_eq(summary_plain, "{\"results\":[]}")
  assert_eq(runtime_plain.catalog_issues.length(), 0)
  // A mixed selector surfaces only the refreshable provider.
  let summary_mixed = refresh_model_lists_live_with(
    make_runtime(),
    [live_plain, plain],
    [live_refreshable],
    snapshot,
    Some(["plainprov", "liveprov"]),
  )
  let entries_mixed = live_refresh_summary_entries(summary_mixed)
  assert_eq(entries_mixed.length(), 1)
  assert_eq(
    live_refresh_entry_field(entries_mixed[0], "provider"),
    Json::string("liveprov"),
  )
  assert_eq(
    live_refresh_entry_field(entries_mixed[0], "status"),
    Json::string("refreshed"),
  )
  live_refresh_test_cleanup(home)
}

///|
/// The exported entry never rejects: a malformed selector rides the summary
/// as a failed entry instead of raising across the JS boundary.
async test "live refresh summary carries a bad selector failure" {
  let runtime = CetasJsRuntime::CetasJsRuntime(
    CetasJsConfig::CetasJsConfig(
      "/tmp/cetas-js-live-refresh-bad-selector", 0, "/tmp/cetas-js-live-refresh-bad-selector",
      "workspace_write", "", "",
    ),
  )
  let summary = refresh_model_lists_live(runtime, "not-json")
  let entries = live_refresh_summary_entries(summary)
  assert_eq(entries.length(), 1)
  assert_eq(
    live_refresh_entry_field(entries[0], "status"),
    Json::string("failed"),
  )
  match live_refresh_entry_field(entries[0], "reason") {
    Json::String(reason) => assert_true(reason.contains("not valid JSON"))
    _ => fail("bad selector must ride the summary as a reason")
  }
}

///|
/// A selector mixing a refreshable id with a provider that has no refresh
/// seam (the "mtplx" case: custom openai-compatible config with no
/// registered refreshable factory) refreshes only the refreshable provider;
/// the plain one is skipped silently — no failed entry, no `provider:""`
/// collapse, no catalog_issues warning.
async test "live refresh skips selector ids without a refresh seam" {
  let home = live_refresh_test_home("skip-mixed")
  let old_catalog = live_refresh_test_catalog("liveprov", [
    "liveprov/old-a", "liveprov/old-b",
  ])
  let new_catalog = live_refresh_test_catalog("liveprov", [
    "liveprov/new-a", "liveprov/new-b",
  ])
  let router = @llm.RouterModelPort::from_catalogs([old_catalog])
  let fixture = FakeLiveRefreshFactory::{
    fixed_id: "liveprov",
    catalog: new_catalog,
    fail_refresh: false,
  }
  let refreshable : &@llm.RefreshableProviderFactory = fixture
  let live_plain : &@llm.ProviderFactory = fixture
  let plain_fixture = FakeLivePlainFactory::{ fixed_id: "plainprov", }
  let plain : &@llm.ProviderFactory = plain_fixture
  let runtime = CetasJsRuntime::CetasJsRuntime(
    CetasJsConfig::CetasJsConfig(home, 0, home, "workspace_write", "", ""),
  )
  runtime.catalog_cache["liveprov"] = old_catalog
  runtime.live_router = Some(router)
  let summary = refresh_model_lists_live_with(
    runtime,
    [live_plain, plain],
    [refreshable],
    @cetas_core.ProviderCredentialSnapshot::ProviderCredentialSnapshot(),
    Some(["liveprov", "plainprov"]),
  )
  // Only the refreshable provider's entry surfaces.
  let entries = live_refresh_summary_entries(summary)
  assert_eq(entries.length(), 1)
  assert_eq(
    live_refresh_entry_field(entries[0], "provider"),
    Json::string("liveprov"),
  )
  assert_eq(
    live_refresh_entry_field(entries[0], "status"),
    Json::string("refreshed"),
  )
  assert_eq(live_refresh_entry_field(entries[0], "slots"), Json::number(2.0))
  live_refresh_entry_absent(entries[0], "reason")
  // The refreshable provider's process cache, router swap, and disk cache
  // effects still hold.
  match runtime.catalog_cache.get("liveprov") {
    Some(catalog) => assert_eq(catalog.slots()[0].id, "liveprov/new-a")
    None => fail("live refresh must update the process cache")
  }
  let ids = router.list_slot_ids()
  assert_eq(ids.length(), 2)
  assert_eq(ids[0], "liveprov/new-a")
  match
    @workspace.read_file_result(
      @workspace.JsWorkspaceFs(),
      home + "/.cetas/model_lists.json",
    ) {
    Content(_) => ()
    _ => fail("live refresh must persist the disk cache")
  }
  // The skipped provider leaves no warning behind.
  assert_eq(runtime.catalog_issues.length(), 0)
  live_refresh_test_cleanup(home)
}

///|
/// A selector made only of providers without a refresh seam refreshes
/// nothing and stays fully silent: an empty results summary, no error, and
/// no catalog_issues entries.
async test "live refresh selector of only non-refreshable ids stays empty and silent" {
  let home = live_refresh_test_home("skip-only")
  let plain_fixture = FakeLivePlainFactory::{ fixed_id: "plainprov", }
  let plain : &@llm.ProviderFactory = plain_fixture
  let no_refreshables : Array[&@llm.RefreshableProviderFactory] = []
  let runtime = CetasJsRuntime::CetasJsRuntime(
    CetasJsConfig::CetasJsConfig(home, 0, home, "workspace_write", "", ""),
  )
  let summary = refresh_model_lists_live_with(
    runtime,
    [plain],
    no_refreshables,
    @cetas_core.ProviderCredentialSnapshot::ProviderCredentialSnapshot(),
    Some(["plainprov"]),
  )
  assert_eq(summary, "{\"results\":[]}")
  assert_eq(runtime.catalog_issues.length(), 0)
  match runtime.catalog_cache.get("plainprov") {
    None => ()
    Some(_) => fail("a skipped provider must not gain a cache entry")
  }
  live_refresh_test_cleanup(home)
}

///|
/// Regression for the reported boot failure: the TS host passes every
/// configured provider id, including custom openai-compatible ids ("mtplx")
/// that have no registered refreshable factory. The live entry must skip
/// them silently instead of collapsing the whole refresh into the single
/// `provider:""` ManifestSchemaError summary. Via the real registry: openai
/// stays selected (unconfigured on this temp home, so it reports one
/// ordinary failed entry) and "mtplx" never appears.
async test "live refresh drops settings-only provider ids from the selector" {
  let home = live_refresh_test_home("mtplx")
  let runtime = CetasJsRuntime::CetasJsRuntime(
    CetasJsConfig::CetasJsConfig(home, 0, home, "workspace_write", "", ""),
  )
  let summary = refresh_model_lists_live(runtime, "[\"openai\",\"mtplx\"]")
  let entries = live_refresh_summary_entries(summary)
  assert_eq(entries.length(), 1)
  assert_eq(
    live_refresh_entry_field(entries[0], "provider"),
    Json::string("openai"),
  )
  match live_refresh_entry_field(entries[0], "reason") {
    Json::String(reason) => assert_true(reason.contains("not configured"))
    _ => fail("the unconfigured openai refresh must carry a reason")
  }
  live_refresh_test_cleanup(home)
}
