///|
/// session_model_restore_wbtest.mbt — branch coverage for the resume-time
/// model restore decision, over seam-injected store/router/warn/persist.

///|
/// Minimal model port so router slots exist without a provider adapter.
struct RestoreTestPort {}

///|
impl @posoco.ModelPort for RestoreTestPort with fn chat(
  _self : RestoreTestPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  raise @posoco.ModelError::Transport(
    "restore test port was not expected to chat",
  )
}

///|
impl @posoco.ModelPort for RestoreTestPort with fn compact(
  _self : RestoreTestPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::Transport(
    "restore test port was not expected to compact",
  )
}

///|
impl @posoco.ModelPort for RestoreTestPort with fn provider_config(
  _self : RestoreTestPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
fn restore_test_slot(
  id~ : String,
  efforts~ : Array[String] = [],
) -> @llm.ModelSlot {
  let port : &@posoco.ModelPort = RestoreTestPort::{ }
  let base = @llm.ModelSlot::ModelSlot(
    id~,
    label=id,
    provider_id="test",
    model_id=id + "-model",
    port~,
  )
  if efforts.is_empty() {
    base
  } else {
    {
      ..base,
      thinking_efforts: efforts,
      default_effort: Some(efforts[0]),
      rebuild_on_effort: Some(_ => base),
    }
  }
}

///|
/// A store carrying one session whose metadata records `slot`/`effort` in
/// the same shape the ext-llm bus event produces.
async fn restore_test_store(
  root : String,
  slot~ : String?,
  effort~ : String? = None,
) -> @fs_session.JsonlSessionStore {
  let store = @fs_session.JsonlSessionStore::JsonlSessionStore(root)
  let metadata : Map[String, Json] = Map::from_array([])
  match slot {
    Some(slot) =>
      metadata[@fs_session.MODEL_SELECTION_METADATA_KEY] = Json::object(
        Map::from_array([
          ("slot_id", Json::string(slot)),
          (
            "effort",
            match effort {
              Some(value) => Json::string(value)
              None => Json::null()
            },
          ),
        ]),
      )
    None => ()
  }
  store.save("sess_restore", { messages: [], metadata, }) catch {
    e => fail("seed session failed: \{e}")
  }
  store
}

///|
async test "restore keeps the current selection when nothing is recorded" {
  let store = restore_test_store("/tmp/cetas-js-restore-none", slot=None)
  let router = @llm.RouterModelPort(slots=[restore_test_slot(id="one/a")])
  let warns : Array[String] = []
  let applied = restore_session_model_selection_over(
    store,
    Providers(router),
    warn=fn(message) { warns.push(message) },
    "sess_restore",
  )
  assert_eq(warns.length(), 0)
  assert_false(applied)
  assert_eq(router.active_slot_id(), "one/a")
}

///|
async test "restore applies the recorded slot and effort" {
  let store = restore_test_store(
    "/tmp/cetas-js-restore-apply",
    slot=Some("one/a"),
    effort=Some("high"),
  )
  let router = @llm.RouterModelPort(slots=[
    restore_test_slot(id="one/a", efforts=["low", "high"]),
    restore_test_slot(id="two/b"),
  ])
  router.switch_slot("two/b") catch {
    _ => fail("unexpected switch failure")
  }
  let warns : Array[String] = []
  let applied = restore_session_model_selection_over(
    store,
    Providers(router),
    warn=fn(message) { warns.push(message) },
    "sess_restore",
  )
  assert_eq(warns.length(), 0)
  assert_true(applied)
  assert_eq(router.active_slot_id(), "one/a")
  assert_eq(router.active_effort(), Some("high"))
}

///|
async test "restore skips when the selection already matches" {
  let store = restore_test_store(
    "/tmp/cetas-js-restore-match",
    slot=Some("one/a"),
    effort=Some("high"),
  )
  let router = @llm.RouterModelPort(
    slots=[restore_test_slot(id="one/a", efforts=["low", "high"])],
    default_slot_id="one/a",
  )
  router.select_effort("one/a", "high") catch {
    _ => fail("unexpected effort failure")
  }
  let warns : Array[String] = []
  let applied = restore_session_model_selection_over(
    store,
    Providers(router),
    warn=fn(message) { warns.push(message) },
    "sess_restore",
  )
  assert_eq(warns.length(), 0)
  assert_false(applied)
  assert_eq(router.active_effort(), Some("high"))
}

///|
async test "restore warns and keeps the selection when the slot is missing" {
  let store = restore_test_store(
    "/tmp/cetas-js-restore-missing",
    slot=Some("ghost/x"),
  )
  let router = @llm.RouterModelPort(slots=[restore_test_slot(id="one/a")])
  let warns : Array[String] = []
  let applied = restore_session_model_selection_over(
    store,
    Providers(router),
    warn=fn(message) { warns.push(message) },
    "sess_restore",
  )
  assert_eq(warns.length(), 1)
  assert_true(warns[0].contains("ghost/x"))
  assert_false(applied)
  assert_eq(router.active_slot_id(), "one/a")
}

///|
async test "restore warns on an unsupported effort but still applies the slot" {
  let store = restore_test_store(
    "/tmp/cetas-js-restore-effort",
    slot=Some("one/a"),
    effort=Some("ultra"),
  )
  let router = @llm.RouterModelPort(slots=[
    restore_test_slot(id="one/a", efforts=["low", "high"]),
  ])
  router.switch_slot("one/a") catch {
    _ => fail("unexpected switch failure")
  }
  let warns : Array[String] = []
  let applied = restore_session_model_selection_over(
    store,
    Providers(router),
    warn=fn(message) { warns.push(message) },
    "sess_restore",
  )
  assert_eq(warns.length(), 1)
  assert_true(warns[0].contains("ultra"))
  assert_true(applied)
  assert_eq(router.active_slot_id(), "one/a")
  assert_eq(router.active_effort(), None)
}

///|
async test "restore honors an owner-qualified model selection" {
  let root = "/tmp/cetas-js-restore-owned"
  let store = restore_test_store(root, slot=None)
  let router = @llm.RouterModelPort(slots=[
    restore_test_slot(id="one/a", efforts=["low", "high"]),
    restore_test_slot(id="two/b"),
  ])
  let control = router as &@modelmgmt.ModelManagerControl
  let metadata : Map[String, Json] = @fs_session.metadata_with_selection_v2(
    Map::from_array([]),
    {
      owner: control.manager_id(),
      model_id: "two/b",
      effort: None,
      pending: false,
      revision: 1L,
    },
  )
  store.save("sess_restore", { messages: [], metadata, }) catch {
    e => fail("seed v2 session failed: \{e}")
  }
  let warns : Array[String] = []
  let applied = restore_session_model_selection_over(
    store,
    Providers(router),
    warn=fn(message) { warns.push(message) },
    "sess_restore",
  )
  assert_true(applied)
  assert_eq(warns.length(), 0)
  assert_eq(router.active_slot_id(), "two/b")
}

///|
async test "restore ignores a selection owned by another model manager" {
  let store = restore_test_store(
    "/tmp/cetas-js-restore-foreign",
    slot=Some("two/b"),
  )
  let router = @llm.RouterModelPort(slots=[
    restore_test_slot(id="one/a"),
    restore_test_slot(id="two/b"),
  ])
  let saved = store.load("sess_restore") catch {
    e => fail("read session failed: \{e}")
  }
  let metadata = @fs_session.metadata_with_selection_v2(saved.metadata, {
    owner: "unrelated-manager",
    model_id: "two/b",
    effort: None,
    pending: false,
    revision: 1L,
  })
  store.save("sess_restore", { messages: [], metadata, }) catch {
    e => fail("save session failed: \{e}")
  }
  let warns : Array[String] = []
  let applied = restore_session_model_selection_over(
    store,
    Providers(router),
    warn=fn(message) { warns.push(message) },
    "sess_restore",
  )
  assert_false(applied)
  assert_eq(warns.length(), 0)
  assert_eq(router.active_slot_id(), "one/a")
}

///|
async test "malformed versioned selection does not fall back to legacy slot" {
  let store = restore_test_store(
    "/tmp/cetas-js-restore-invalid",
    slot=Some("two/b"),
  )
  let router = @llm.RouterModelPort(slots=[
    restore_test_slot(id="one/a"),
    restore_test_slot(id="two/b"),
  ])
  let saved = store.load("sess_restore") catch {
    e => fail("read session failed: \{e}")
  }
  let metadata = saved.metadata.copy()
  metadata[@fs_session.MODEL_SELECTION_V2_METADATA_KEY] = Json::object(
    Map::from_array([
      ("version", Json::number(2)),
      ("model_id", Json::string("two/b")),
    ]),
  )
  store.save("sess_restore", { messages: [], metadata, }) catch {
    e => fail("save session failed: \{e}")
  }
  let applied = restore_session_model_selection_over(
    store,
    Providers(router),
    warn=fn(_message) { () },
    "sess_restore",
  )
  assert_false(applied)
  assert_eq(router.active_slot_id(), "one/a")
}
