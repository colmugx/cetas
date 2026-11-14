///|
/// Whitebox tests for the bounded native replay boundary. The oracle is the
/// shared `transcript_json` projection in `transcript.mbt`: any item a page
/// returns must be exactly the item the whole-session replay would produce
/// (plus the absolute `index` field the paged surface adds).
/// Native-only bounded replay tests.

///|
fn replay_test_field(json : Json, key : String) -> Json {
  match json {
    Json::Object(fields) =>
      match fields.get(key) {
        Some(value) => value
        None => Json::null()
      }
    _ => Json::null()
  }
}

///|
fn replay_test_has(json : Json, key : String) -> Bool {
  match json {
    Json::Object(fields) => fields.contains(key)
    _ => false
  }
}

///|
fn replay_test_string(json : Json, key : String) -> String {
  match replay_test_field(json, key) {
    Json::String(value) => value
    _ => abort("expected string field " + key)
  }
}

///|
fn replay_test_int(json : Json, key : String) -> Int32 {
  match replay_test_field(json, key) {
    Json::Number(value, ..) => value.to_int()
    _ => abort("expected integer field " + key)
  }
}

///|
fn replay_test_items(json : Json) -> Array[Json] {
  match replay_test_field(json, "items") {
    Json::Array(items) => items
    _ => abort("expected an items array")
  }
}

///|
fn replay_test_error(json : Json) -> String {
  match replay_test_field(json, "error") {
    Json::String(value) => value
    _ => ""
  }
}

///|
/// Page items carry the absolute `index`; the oracle does not. Dropping it makes
/// the two item shapes directly comparable.
fn replay_test_without_index(item : Json) -> Json {
  match item {
    Json::Object(fields) => {
      fields.remove("index")
      Json::object(fields)
    }
    _ => item
  }
}

///|
fn replay_test_utf8_len(text : String) -> Int32 {
  @utf8.encode(text).length()
}

///|
async fn replay_test_teardown(root : String) -> Unit noraise {
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
/// Fetch one block's payload through bounded `transcript_source` chunks and
/// reassemble it, asserting every frame stays under the 4 MiB host limit.
async fn replay_test_collect_source(
  cache : NativeReplayCache,
  id : String,
  path : String,
  revision : String,
  block : Int32,
  field : String,
) -> (String, Int32) {
  let builder = StringBuilder()
  let mut offset = 0
  let mut frames = 0
  while true {
    let source = native_replay_source_json(
      cache, id, path, revision, block, field, offset, 0,
    )
    let error = replay_test_error(source)
    if error != "" {
      abort("transcript_source failed: " + error)
    }
    if @utf8.encode(source.stringify()).length() >= 4 * 1024 * 1024 {
      abort("transcript_source frame exceeded the 4 MiB host limit")
    }
    let chunk = replay_test_string(source, "data")
    if @utf8.encode(chunk).length() > REPLAY_SOURCE_MAX_BYTES {
      abort("transcript_source chunk exceeded REPLAY_SOURCE_MAX_BYTES")
    }
    builder.write_string(chunk)
    frames += 1
    match replay_test_field(source, "next") {
      Json::Number(next, ..) => offset = next.to_int()
      Json::Null => break
      _ => abort("source next must be an integer or null")
    }
  }
  (builder.to_string(), frames)
}

///|
async fn replay_test_save(
  root : String,
  id : String,
  session : @posoco_types.Session,
) -> String {
  let store = @fs_session.JsonlSessionStore::JsonlSessionStore(root)
  store.save(id, session)
  @fs_session.jsonl_session_path(root, id)
}

///|
/// A representative journal: system, user, assistant (reasoning + text + two
/// tool calls), one success and one reported-error result, a follow-up user,
/// an empty-content user (projects no item, still advances `turnId`), and a
/// final assistant text.
fn replay_test_session() -> @posoco_types.Session {
  @posoco_types.Session::{
    messages: [
      @kernel.Message::SystemMessage(content=[@kernel.Content::Text("sys")]),
      @kernel.Message::UserMessage(content=[@kernel.Content::Text("hello")]),
      @kernel.Message::AssistantMessage(
        content=[@kernel.Content::Text("answer")],
        tool_calls=[
          @kernel.ToolCall::{
            call_id: @kernel.CallId::unchecked("c1"),
            name: @kernel.ToolName::unchecked("read"),
            arguments: Json::object(
              Map::from_array([("path", Json::string("a.txt"))]),
            ),
          },
          @kernel.ToolCall::{
            call_id: @kernel.CallId::unchecked("c2"),
            name: @kernel.ToolName::unchecked("bash"),
            arguments: Json::object(
              Map::from_array([("cmd", Json::string("false"))]),
            ),
          },
        ],
        reasoning=Some(@kernel.Reasoning::{ content: "think", raw: None, }),
        finish_reason=@kernel.FinishReason::ToolCalls,
      ),
      @kernel.Message::ToolMessage(
        call_id=@kernel.CallId::unchecked("c1"),
        tool_name=@kernel.ToolName::unchecked("read"),
        outcome=@kernel.ToolOutcome::Success(
          content="file body",
          structured=None,
        ),
      ),
      @kernel.Message::ToolMessage(
        call_id=@kernel.CallId::unchecked("c2"),
        tool_name=@kernel.ToolName::unchecked("bash"),
        outcome=@kernel.ToolOutcome::ToolReportedError(
          content="boom",
          structured=None,
        ),
      ),
      @kernel.Message::UserMessage(content=[@kernel.Content::Text("follow up")]),
      @kernel.Message::UserMessage(content=[]),
      @kernel.Message::AssistantMessage(
        content=[@kernel.Content::Text("done")],
        tool_calls=[],
        reasoning=None,
        finish_reason=@kernel.FinishReason::Stop,
      ),
    ],
    metadata: Map::from_array([
      ("name", Json::string("Fixture")),
      (
        "posoco.context_state",
        Json::object(Map::from_array([("tokens", Json::number(12.0))])),
      ),
    ]),
  }
}

///|
async fn replay_test_oracle(root : String) -> (@posoco_types.Session, String) {
  let session = replay_test_session()
  let id = "s-oracle"
  let path = replay_test_save(root, id, session)
  (session, path)
}

///|
async test "replay page items match the transcript_json oracle" {
  let root = @fs.tmpdir(prefix="cetas-replay-oracle-")
  let (session, path) = replay_test_oracle(root)
  let oracle = transcript_json(session)
  let oracle_items = replay_test_items(oracle)
  assert_eq(oracle_items.length(), 7)
  let cache = NativeReplayCache::new()
  let page = native_replay_page_json(cache, "s-oracle", path, "", 0, 100, 0)
  assert_eq(replay_test_error(page), "")
  assert_eq(replay_test_int(page, "total"), 7)
  let items = replay_test_items(page)
  assert_eq(items.length(), oracle_items.length())
  for index in 0..<items.length() {
    assert_eq(replay_test_int(items[index], "index"), index)
    assert_eq(
      replay_test_without_index(items[index]).stringify(),
      oracle_items[index].stringify(),
    )
  }
  // There is no page after the last item.
  assert_true(replay_test_field(page, "next") is Json::Null)
  replay_test_teardown(root)
}

///|
async test "replay pages are stable and contiguous through next" {
  let root = @fs.tmpdir(prefix="cetas-replay-pages-")
  let (session, path) = replay_test_oracle(root)
  let oracle_items = replay_test_items(transcript_json(session))
  let cache = NativeReplayCache::new()
  let collected : Array[Json] = []
  let mut first = 0
  while first < oracle_items.length() {
    let page = native_replay_page_json(cache, "s-oracle", path, "", first, 2, 0)
    assert_eq(replay_test_error(page), "")
    let items = replay_test_items(page)
    assert_true(items.length() > 0)
    for item in items {
      collected.push(item)
    }
    first += items.length()
    match replay_test_field(page, "next") {
      Json::Number(next, ..) => assert_eq(next.to_int(), first)
      Json::Null => assert_eq(first, oracle_items.length())
      _ => abort("next must be an integer or null")
    }
  }
  assert_eq(collected.length(), oracle_items.length())
  for index in 0..<collected.length() {
    assert_eq(replay_test_int(collected[index], "index"), index)
    assert_eq(
      replay_test_without_index(collected[index]).stringify(),
      oracle_items[index].stringify(),
    )
  }
  replay_test_teardown(root)
}

///|
async test "replay resolves a tool result across the page boundary" {
  let root = @fs.tmpdir(prefix="cetas-replay-tools-")
  let (session, path) = replay_test_oracle(root)
  let oracle_items = replay_test_items(transcript_json(session))
  let cache = NativeReplayCache::new()
  // Block 3 is the first tool call; its result lives on a later line.
  let page = native_replay_page_json(cache, "s-oracle", path, "", 3, 1, 0)
  assert_eq(replay_test_error(page), "")
  let items = replay_test_items(page)
  assert_eq(items.length(), 1)
  assert_eq(replay_test_int(items[0], "index"), 3)
  assert_eq(replay_test_string(items[0], "kind"), "tool")
  assert_eq(replay_test_string(items[0], "status"), "done")
  assert_eq(replay_test_string(items[0], "result"), "file body")
  assert_eq(
    replay_test_without_index(items[0]).stringify(),
    oracle_items[3].stringify(),
  )
  // A page that ends exactly at the tool call still carries the later result.
  let edge = native_replay_page_json(cache, "s-oracle", path, "", 0, 4, 0)
  let edge_items = replay_test_items(edge)
  assert_eq(edge_items.length(), 4)
  assert_eq(replay_test_string(edge_items[3], "status"), "done")
  assert_eq(replay_test_string(edge_items[3], "result"), "file body")
  // The error result is resolved the same way.
  let second = native_replay_page_json(cache, "s-oracle", path, "", 4, 1, 0)
  let second_items = replay_test_items(second)
  assert_eq(replay_test_string(second_items[0], "status"), "error")
  assert_eq(replay_test_string(second_items[0], "result"), "boom")
  replay_test_teardown(root)
}

///|
async test "replay index is light metadata with absolute indexes" {
  let root = @fs.tmpdir(prefix="cetas-replay-index-")
  let (session, path) = replay_test_oracle(root)
  let oracle_items = replay_test_items(transcript_json(session))
  let cache = NativeReplayCache::new()
  let index = native_replay_index_json(cache, "s-oracle", path, -1, 0)
  assert_eq(replay_test_error(index), "")
  // The context state is the same metadata payload the oracle projects.
  assert_eq(
    replay_test_field(index, "context").stringify(),
    replay_test_field(transcript_json(session), "context").stringify(),
  )
  assert_eq(replay_test_int(index, "total"), oracle_items.length())
  let items = replay_test_items(index)
  assert_eq(items.length(), oracle_items.length())
  assert_eq(replay_test_int(index, "first"), 0)
  for position in 0..<items.length() {
    let item = items[position]
    assert_eq(replay_test_int(item, "index"), position)
    assert_eq(
      replay_test_string(item, "kind"),
      replay_test_string(oracle_items[position], "kind"),
    )
    assert_eq(
      replay_test_string(item, "turnId"),
      replay_test_string(oracle_items[position], "turnId"),
    )
    // Bodies never ride the index, only their byte lengths.
    assert_false(replay_test_has(item, "text"))
    assert_false(replay_test_has(item, "result"))
    assert_false(replay_test_has(item, "args"))
    match replay_test_field(oracle_items[position], "kind") {
      Json::String("tool") => {
        assert_eq(
          replay_test_string(item, "callId"),
          replay_test_string(oracle_items[position], "callId"),
        )
        assert_eq(
          replay_test_string(item, "name"),
          replay_test_string(oracle_items[position], "name"),
        )
        assert_eq(
          replay_test_string(item, "status"),
          replay_test_string(oracle_items[position], "status"),
        )
        assert_eq(
          replay_test_int(item, "resultBytes"),
          replay_test_utf8_len(
            replay_test_string(oracle_items[position], "result"),
          ),
        )
      }
      _ =>
        assert_eq(
          replay_test_int(item, "textBytes"),
          replay_test_utf8_len(
            replay_test_string(oracle_items[position], "text"),
          ),
        )
    }
  }
  // The default window starts near the tail; explicit paging starts earlier.
  let tail_only = native_replay_index_json(cache, "s-oracle", path, -1, 2)
  let tail_items = replay_test_items(tail_only)
  assert_eq(tail_items.length(), 2)
  assert_eq(replay_test_int(tail_only, "first"), 5)
  assert_eq(replay_test_int(tail_items[0], "index"), 5)
  let earlier = native_replay_index_json(cache, "s-oracle", path, 1, 2)
  let earlier_items = replay_test_items(earlier)
  assert_eq(replay_test_int(earlier_items[0], "index"), 1)
  replay_test_teardown(root)
}

///|
async test "replay tolerates a torn tail but reports explicit corruption" {
  let root = @fs.tmpdir(prefix="cetas-replay-torn-")
  let (session, path) = replay_test_oracle(root)
  let oracle_items = replay_test_items(transcript_json(session))
  @fs.write_file(
    path,
    "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"part",
    append=true,
    create_mode=@fs.CreateMode::OpenExisting,
  ) catch {
    error => abort("torn-tail append failed: " + error.to_string())
  }
  let cache = NativeReplayCache::new()
  let page = native_replay_page_json(cache, "s-oracle", path, "", 0, 100, 0)
  assert_eq(replay_test_error(page), "")
  assert_eq(replay_test_int(page, "total"), oracle_items.length())
  let items = replay_test_items(page)
  assert_eq(items.length(), oracle_items.length())
  for index in 0..<items.length() {
    assert_eq(
      replay_test_without_index(items[index]).stringify(),
      oracle_items[index].stringify(),
    )
  }
  // A complete but malformed line is corruption, not a torn tail.
  let lines = @fs.read_file(path).text()
  let broken = lines.split("\n").to_array()
  let corrupted = StringBuilder()
  for index in 0..<broken.length() {
    if index == 2 {
      corrupted.write_string("{not json}")
    } else {
      corrupted.write_string(broken[index].to_owned())
    }
    corrupted.write_char('\n')
  }
  @fs.write_file(
    path,
    corrupted.to_string(),
    create_mode=@fs.CreateMode::CreateOrTruncate,
  ) catch {
    error => abort("corruption rewrite failed: " + error.to_string())
  }
  let corrupt_cache = NativeReplayCache::new()
  let corrupt = native_replay_page_json(
    corrupt_cache, "s-oracle", path, "", 0, 100, 0,
  )
  assert_true(replay_test_error(corrupt).contains("malformed transcript line"))
  let corrupt_index = native_replay_index_json(
    corrupt_cache, "s-oracle", path, -1, 0,
  )
  assert_true(
    replay_test_error(corrupt_index).contains("malformed transcript line"),
  )
  replay_test_teardown(root)
}

///|
async test "giant bodies stay bounded and round-trip through transcript_source" {
  let root = @fs.tmpdir(prefix="cetas-replay-giant-")
  let big = "x".repeat(6 * 1024 * 1024)
  let big_prompt = "z".repeat(5 * 1024 * 1024)
  let session = @posoco_types.Session::{
    messages: [
      @kernel.Message::UserMessage(content=[@kernel.Content::Text(big_prompt)]),
      @kernel.Message::AssistantMessage(
        content=[],
        tool_calls=[
          @kernel.ToolCall::{
            call_id: @kernel.CallId::unchecked("big"),
            name: @kernel.ToolName::unchecked("read"),
            arguments: Json::object(Map::from_array([])),
          },
        ],
        reasoning=None,
        finish_reason=@kernel.FinishReason::ToolCalls,
      ),
      @kernel.Message::ToolMessage(
        call_id=@kernel.CallId::unchecked("big"),
        tool_name=@kernel.ToolName::unchecked("read"),
        outcome=@kernel.ToolOutcome::Success(content=big, structured=None),
      ),
      @kernel.Message::AssistantMessage(
        content=[],
        tool_calls=[
          @kernel.ToolCall::{
            call_id: @kernel.CallId::unchecked("args"),
            name: @kernel.ToolName::unchecked("write"),
            arguments: Json::object(
              Map::from_array([
                ("blob", Json::string("a".repeat(5 * 1024 * 1024))),
              ]),
            ),
          },
        ],
        reasoning=None,
        finish_reason=@kernel.FinishReason::ToolCalls,
      ),
    ],
    metadata: Map::from_array([]),
  }
  let id = "s-giant"
  let path = replay_test_save(root, id, session)
  let cache = NativeReplayCache::new()
  let page = native_replay_page_json(cache, id, path, "", 0, 100, 0)
  assert_eq(replay_test_error(page), "")
  // The whole page frame is far below the 4 MiB host limit.
  assert_true(@utf8.encode(page.stringify()).length() < 4 * 1024 * 1024)
  let items = replay_test_items(page)
  assert_eq(items.length(), 3)
  // A giant user prompt is a preview plus a textRef on the same item.
  let prompt_item = items[0]
  assert_eq(replay_test_string(prompt_item, "kind"), "user")
  assert_true(
    replay_test_string(prompt_item, "text").length() <= REPLAY_PREVIEW_CHARS,
  )
  let text_ref = replay_test_field(prompt_item, "textRef")
  assert_eq(
    replay_test_int(text_ref, "length"),
    replay_test_utf8_len(big_prompt),
  )
  let tool = items[1]
  assert_eq(replay_test_string(tool, "status"), "done")
  assert_true(
    replay_test_string(tool, "result").length() <= REPLAY_PREVIEW_CHARS,
  )
  let result_ref = replay_test_field(tool, "resultRef")
  assert_eq(replay_test_int(result_ref, "length"), replay_test_utf8_len(big))
  assert_eq(replay_test_int(result_ref, "offset"), 0)
  // Ref ranges are fetched in bounded chunks that reassemble the exact body.
  let revision = replay_test_string(page, "revision")
  let (result_body, frames) = replay_test_collect_source(
    cache,
    id,
    path,
    revision,
    replay_test_int(tool, "index"),
    "",
  )
  assert_eq(result_body, big)
  assert_eq(frames, 6)
  // The giant user prompt round-trips the same way.
  let (prompt_body, prompt_frames) = replay_test_collect_source(
    cache, id, path, revision, 0, "",
  )
  assert_eq(prompt_body, big_prompt)
  assert_eq(prompt_frames, 5)
  // Giant tool-call arguments are a ref too, served with `field: "args"`.
  let args_item = items[2]
  assert_eq(replay_test_string(args_item, "kind"), "tool")
  assert_eq(replay_test_field(args_item, "args").stringify(), "null")
  let args_ref = replay_test_field(args_item, "argsRef")
  assert_eq(replay_test_string(args_ref, "field"), "args")
  let expected_args = Json::object(
    Map::from_array([("blob", Json::string("a".repeat(5 * 1024 * 1024)))]),
  )
  assert_eq(
    replay_test_int(args_ref, "length"),
    replay_test_utf8_len(expected_args.stringify()),
  )
  let (args_body, args_frames) = replay_test_collect_source(
    cache,
    id,
    path,
    revision,
    replay_test_int(args_item, "index"),
    "args",
  )
  assert_eq(args_body, expected_args.stringify())
  assert_eq(args_frames, 6)
  replay_test_teardown(root)
}

///|
async test "native session summaries stream metadata and first-user title" {
  let root = @fs.tmpdir(prefix="cetas-replay-summary-")
  let store = @fs_session.JsonlSessionStore::JsonlSessionStore(root)
  // Metadata title wins over the first user line.
  let named = @posoco_types.Session::{
    messages: [
      @kernel.Message::UserMessage(content=[@kernel.Content::Text("ignored")]),
    ],
    metadata: Map::from_array([
      ("name", Json::string("Named session")),
      ("posoco.title", Json::string("  Generated   title ")),
    ]),
  }
  store.save("s-named", named)
  let named_summary = match
    native_replay_summary(
      "s-named",
      @fs_session.jsonl_session_path(root, "s-named"),
    ) {
    Ok(summary) => summary
    Err(reason) => abort("named summary failed: " + reason)
  }
  assert_eq(named_summary.title, "Named session")
  // Legacy journal: no metadata title, so the first user line is normalized.
  let big = "y".repeat(5 * 1024 * 1024)
  let legacy = @posoco_types.Session::{
    messages: [
      @kernel.Message::SystemMessage(content=[@kernel.Content::Text("sys")]),
      @kernel.Message::UserMessage(content=[
        @kernel.Content::Text("  hello   world  "),
      ]),
      @kernel.Message::AssistantMessage(
        content=[@kernel.Content::Text(big)],
        tool_calls=[],
        reasoning=None,
        finish_reason=@kernel.FinishReason::Stop,
      ),
    ],
    metadata: Map::from_array([]),
  }
  store.save("s-legacy", legacy)
  let legacy_path = @fs_session.jsonl_session_path(root, "s-legacy")
  let legacy_summary = match native_replay_summary("s-legacy", legacy_path) {
    Ok(summary) => summary
    Err(reason) => abort("legacy summary failed: " + reason)
  }
  assert_eq(legacy_summary.title, "hello world")
  // The summary never reads the giant assistant line behind the first user.
  assert_true(
    legacy_summary.scanned <=
    REPLAY_SUMMARY_SCAN_BYTES + REPLAY_SUMMARY_CHUNK_BYTES.to_int64(),
  )
  // Oracle: the fs-session summary projection resolves the same display title.
  let oracle = store.summary("s-legacy")
  assert_eq(@fs_session.display_title(oracle), legacy_summary.title)
  // Corruption is explicit, never normalized into an id-shaped title.
  let bad_path = @fs_session.jsonl_session_path(root, "s-bad")
  @fs.write_file(bad_path, "{not json}\n") catch {
    error => abort("bad summary fixture failed: " + error.to_string())
  }
  match native_replay_summary("s-bad", bad_path) {
    Ok(_) => abort("corrupt metadata must not produce a silent title")
    Err(reason) =>
      assert_true(reason.contains("malformed session summary metadata line"))
  }
  // A torn tail is recovery, not corruption: the torn line is ignored and the
  // title comes from the persisted prefix (here nothing, so the id), exactly as
  // the classic summary over the same bytes resolves it.
  let torn_id = "s-torn-tail"
  let torn_path = @fs_session.jsonl_session_path(root, torn_id)
  @fs.write_file(
    torn_path, "{}\n{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"gone",
  ) catch {
    error => abort("torn summary fixture failed: " + error.to_string())
  }
  let torn_summary = match native_replay_summary(torn_id, torn_path) {
    Ok(summary) => summary
    Err(reason) => abort("torn tail must not fail the summary: " + reason)
  }
  assert_eq(torn_summary.title, torn_id)
  assert_eq(
    @fs_session.display_title(store.summary(torn_id)),
    torn_summary.title,
  )
  replay_test_teardown(root)
}

///|
test "catalog replay path validates ids and keeps the jsonl layout" {
  let store = @fs_session.JsonlSessionStore::JsonlSessionStore(
    "/tmp/cetas-replay-catalog",
  )
  let catalog = FsSessionCatalog::new(store)
  assert_eq(
    SessionCatalog::transcript_path(catalog, "bad/id"),
    Err("session id must not contain path separators"),
  )
  match SessionCatalog::transcript_path(catalog, "s-1") {
    Ok(path) => assert_eq(path, "/tmp/cetas-replay-catalog/s-1.jsonl")
    Err(reason) => abort("valid session path rejected: " + reason)
  }
}

///|
/// Runtime seam: the new commands are native-only, while the shared
/// `session_transcript` path keeps its exact existing behavior. The native
/// session list resolves titles by streaming, and produces the same title the
/// shared summary projection does.
async test "replay commands are native-only and leave the shared transcript unchanged" {
  @async.with_task_group(group => {
    let cwd = @fs.tmpdir(prefix="cetas-replay-runtime-ws-")
    let home = @fs.tmpdir(prefix="cetas-replay-runtime-home-")
    @fs.mkdir(home + "/.cetas", recursive=true) catch {
      error => abort("runtime home setup failed: " + error.to_string())
    }
    @fs.write_file(
      home + "/.cetas/settings.json",
      "{\"providers\":{\"opencode\":{\"api_key\":\"sk-fixture\"}}}",
    ) catch {
      error => abort("runtime settings failed: " + error.to_string())
    }
    let session = replay_test_session()
    let store = @fs_session.JsonlSessionStore::of_project(home~, cwd~)
    store.save("s-runtime", session)
    let fs_impl = @workspace.NativeWorkspaceFs()
    let fs : &@workspace.WorkspaceFs = fs_impl
    let oracle = transcript_json(session)
    let shared = compose_console_runtime(
      console_config(fs, home, "cetas-web", "cetas-web/0.1"),
      cwd,
      group,
    )
    // The shared host keeps replaying through `load`, unchanged.
    assert_eq(
      shared.transcript_json("s-runtime").stringify(),
      oracle.stringify(),
    )
    // The bounded commands never activate without the native projection.
    assert_true(
      replay_test_error(shared.transcript_index_json("s-runtime")).contains(
        "native-only",
      ),
    )
    assert_true(
      replay_test_error(shared.transcript_page_json("s-runtime", "", 0, 10, 0)).contains(
        "native-only",
      ),
    )
    assert_true(
      replay_test_error(
        shared.transcript_source_json("s-runtime", "", 0, offset=0, length=0),
      ).contains("native-only"),
    )
    let shared_sessions = shared.sessions_json()
    shared.shutdown_all()
    let native = compose_console_runtime(
      console_config(fs, home, "cetas-go", "cetas-go/0.1", native_ui=true),
      cwd,
      group,
    )
    let index = native.transcript_index_json("s-runtime")
    assert_eq(replay_test_error(index), "")
    assert_eq(replay_test_int(index, "total"), 7)
    let page = native.transcript_page_json("s-runtime", "", 0, 100, 0)
    let items = replay_test_items(page)
    let oracle_items = replay_test_items(oracle)
    for position in 0..<items.length() {
      assert_eq(
        replay_test_without_index(items[position]).stringify(),
        oracle_items[position].stringify(),
      )
    }
    // Native session summaries stream and match the shared summary titles.
    let native_sessions = native.sessions_json()
    assert_eq(
      replay_test_string(
        replay_test_session_entry(native_sessions, "s-runtime"),
        "title",
      ),
      replay_test_string(
        replay_test_session_entry(shared_sessions, "s-runtime"),
        "title",
      ),
    )
    native.shutdown_all()
    permission_fixture_cleanup(cwd)
    permission_fixture_cleanup(home)
  })
}

///|
fn replay_test_session_entry(sessions : Json, id : String) -> Json {
  match replay_test_field(sessions, "sessions") {
    Json::Array(entries) =>
      for entry in entries {
        if replay_test_string(entry, "id") == id {
          return entry
        }
      }
    _ => ()
  }
  abort("session entry missing: " + id)
}

///|
/// A ToolMessage far beyond any fixed lookahead window still settles the page's
/// tool item; a call with no result at all stays `running`, which is the only
/// truthful state for an interrupted journal.
async test "replay settles far tool results and never fabricates running" {
  let root = @fs.tmpdir(prefix="cetas-replay-far-tool-")
  let filler = "f".repeat(16 * 1024)
  let messages : Array[@kernel.Message] = [
    @kernel.Message::UserMessage(content=[@kernel.Content::Text("start")]),
    @kernel.Message::AssistantMessage(
      content=[],
      tool_calls=[
        @kernel.ToolCall::{
          call_id: @kernel.CallId::unchecked("c-far"),
          name: @kernel.ToolName::unchecked("read"),
          arguments: Json::object(Map::from_array([])),
        },
      ],
      reasoning=None,
      finish_reason=@kernel.FinishReason::ToolCalls,
    ),
  ]
  let mut index = 0
  while index < 300 {
    messages.push(
      @kernel.Message::UserMessage(content=[@kernel.Content::Text(filler)]),
    )
    index += 1
  }
  messages.push(
    @kernel.Message::ToolMessage(
      call_id=@kernel.CallId::unchecked("c-far"),
      tool_name=@kernel.ToolName::unchecked("read"),
      outcome=@kernel.ToolOutcome::Success(
        content="late result",
        structured=None,
      ),
    ),
  )
  messages.push(
    @kernel.Message::AssistantMessage(
      content=[@kernel.Content::Text("done")],
      tool_calls=[],
      reasoning=None,
      finish_reason=@kernel.FinishReason::Stop,
    ),
  )
  let session = @posoco_types.Session::{ messages, metadata: Map([]), }
  let path = replay_test_save(root, "s-far", session)
  // The filler is both more than 256 lines and more than 4 MiB, i.e. behind
  // every fixed lookahead window a bounded reader could choose.
  let far_size : Int64 = @fs.file_size(path) catch { _ => 0L }
  assert_true(far_size > 4L * 1024L * 1024L)
  let cache = NativeReplayCache::new()
  let page = native_replay_page_json(cache, "s-far", path, "", 1, 1, 0)
  assert_eq(replay_test_error(page), "")
  let items = replay_test_items(page)
  assert_eq(items.length(), 1)
  assert_eq(replay_test_string(items[0], "status"), "done")
  assert_eq(replay_test_string(items[0], "result"), "late result")
  assert_eq(
    replay_test_without_index(items[0]).stringify(),
    replay_test_items(transcript_json(session))[1].stringify(),
  )
  // An interrupted journal has no result line: running, not a fake `done`.
  let interrupted = @posoco_types.Session::{
    messages: [
      @kernel.Message::UserMessage(content=[@kernel.Content::Text("start")]),
      @kernel.Message::AssistantMessage(
        content=[],
        tool_calls=[
          @kernel.ToolCall::{
            call_id: @kernel.CallId::unchecked("c-open"),
            name: @kernel.ToolName::unchecked("read"),
            arguments: Json::object(Map::from_array([])),
          },
        ],
        reasoning=None,
        finish_reason=@kernel.FinishReason::ToolCalls,
      ),
    ],
    metadata: Map([]),
  }
  let open_path = replay_test_save(root, "s-open", interrupted)
  let open_page = native_replay_page_json(
    cache, "s-open", open_path, "", 1, 1, 0,
  )
  let open_items = replay_test_items(open_page)
  assert_eq(replay_test_string(open_items[0], "status"), "running")
  assert_eq(replay_test_string(open_items[0], "result"), "")
  assert_eq(
    replay_test_without_index(open_items[0]).stringify(),
    replay_test_items(transcript_json(interrupted))[1].stringify(),
  )
  replay_test_teardown(root)
}

///|
/// Regression: a nested `{"role":"tool"}` in tool-call arguments must not be
/// mistaken for the message role when the line straddles the reader's chunk
/// boundary. Misdetection would undercount blocks and shift every later
/// absolute index.
async test "replay role detection is anchored to the line start" {
  let root = @fs.tmpdir(prefix="cetas-replay-role-anchor-")
  fn make_session(padding : Int32) -> @posoco_types.Session {
    @posoco_types.Session::{
      messages: [
        @kernel.Message::UserMessage(content=[
          @kernel.Content::Text("u".repeat(padding)),
        ]),
        @kernel.Message::AssistantMessage(
          content=[],
          tool_calls=[
            @kernel.ToolCall::{
              call_id: @kernel.CallId::unchecked("c-nested"),
              name: @kernel.ToolName::unchecked("x"),
              arguments: Json::object(
                Map::from_array([("role", Json::string("tool"))]),
              ),
            },
          ],
          reasoning=None,
          finish_reason=@kernel.FinishReason::ToolCalls,
        ),
      ],
      metadata: Map([]),
    }
  }
  // Locate the nested pattern in the canonical serialization, then pad the
  // user line so the pattern starts exactly on a 64 KiB chunk boundary.
  let base = @fs_session.session_to_jsonl(make_session(0))
  let marker = "\"arguments\":{\"role\":\"tool\"}"
  let at = match base.find(marker) {
    Some(at) => at + 13
    None => abort("nested role marker missing from serialization")
  }
  let chunk = REPLAY_CHUNK_BYTES
  let padding = (chunk - at % chunk) % chunk
  let session = make_session(padding)
  let path = replay_test_save(root, "s-role", session)
  let cache = NativeReplayCache::new()
  let page = native_replay_page_json(cache, "s-role", path, "", 0, 10, 0)
  assert_eq(replay_test_error(page), "")
  let oracle = replay_test_items(transcript_json(session))
  let items = replay_test_items(page)
  assert_eq(replay_test_int(page, "total"), oracle.length())
  assert_eq(items.length(), oracle.length())
  for index in 0..<items.length() {
    assert_eq(replay_test_int(items[index], "index"), index)
    assert_eq(
      replay_test_without_index(items[index]).stringify(),
      oracle[index].stringify(),
    )
  }
  assert_eq(replay_test_string(items[1], "kind"), "tool")
  replay_test_teardown(root)
}

///|
/// Append-only growth (every live turn) must extend the cached line table, not
/// re-read the whole journal. Existing absolute block indexes stay fixed; the
/// new tool result settles across the append boundary.
async test "replay extends append-only journals without a full rebuild" {
  let root = @fs.tmpdir(prefix="cetas-replay-append-")
  let session = replay_test_session()
  let path = replay_test_save(root, "s-append", session)
  let cache = NativeReplayCache::new()
  let first = match native_replay_index_for(cache, "s-append", path) {
    Ok(index) => index
    Err(reason) => abort("initial index failed: " + reason)
  }
  assert_false(first.incremental)
  assert_eq(first.total, 7)
  @fs.write_file(
    path,
    "{\"role\":\"assistant\",\"content\":[],\"tool_calls\":[{\"id\":\"c-new\",\"name\":\"read\",\"arguments\":{}}]}\n" +
    "{\"role\":\"tool\",\"content\":[{\"type\":\"text\",\"text\":\"new body\"}],\"tool_call_id\":\"c-new\",\"name\":\"read\"}\n" +
    "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"appended\"}]}\n",
    append=true,
    create_mode=@fs.CreateMode::OpenExisting,
  ) catch {
    error => abort("append failed: " + error.to_string())
  }
  let grown = match native_replay_index_for(cache, "s-append", path) {
    Ok(index) => index
    Err(reason) => abort("append extension failed: " + reason)
  }
  assert_true(grown.incremental)
  assert_eq(grown.total, 9)
  let store = @fs_session.JsonlSessionStore::JsonlSessionStore(root)
  let loaded = store.load("s-append") catch { _ => abort("oracle load failed") }
  let oracle_items = replay_test_items(transcript_json(loaded))
  assert_eq(oracle_items.length(), 9)
  let page = native_replay_page_json(
    cache,
    "s-append",
    path,
    grown.revision,
    0,
    100,
    0,
  )
  assert_eq(replay_test_error(page), "")
  let items = replay_test_items(page)
  assert_eq(items.length(), oracle_items.length())
  for index in 0..<items.length() {
    assert_eq(replay_test_int(items[index], "index"), index)
    assert_eq(
      replay_test_without_index(items[index]).stringify(),
      oracle_items[index].stringify(),
    )
  }
  // The appended call at block 7 is settled by its appended ToolMessage.
  assert_eq(replay_test_string(items[7], "kind"), "tool")
  assert_eq(replay_test_string(items[7], "status"), "done")
  assert_eq(replay_test_string(items[7], "result"), "new body")
  // A page opened on an older revision still sees stable absolute indexes.
  let middle = native_replay_page_json(cache, "s-append", path, "", 3, 1, 0)
  assert_eq(
    replay_test_without_index(replay_test_items(middle)[0]).stringify(),
    oracle_items[3].stringify(),
  )
  replay_test_teardown(root)
}

///|
/// Anything that breaks the append-only prefix contract falls back to a full
/// rebuild: a metadata rewrite (same size) must refresh `context`, and a
/// truncating rewrite must replace the line table.
async test "replay rebuilds when the journal prefix is not append-only" {
  let root = @fs.tmpdir(prefix="cetas-replay-rebuild-")
  let session = replay_test_session()
  let path = replay_test_save(root, "s-rebuild", session)
  let store = @fs_session.JsonlSessionStore::JsonlSessionStore(root)
  let cache = NativeReplayCache::new()
  let first = match native_replay_index_for(cache, "s-rebuild", path) {
    Ok(index) => index
    Err(reason) => abort("initial index failed: " + reason)
  }
  assert_false(first.incremental)
  // Same-size metadata rewrite: only the context value changed (12 -> 13).
  let mutated = @posoco_types.Session::{
    messages: session.messages,
    metadata: Map::from_array([
      ("name", Json::string("Fixture")),
      (
        "posoco.context_state",
        Json::object(Map::from_array([("tokens", Json::number(13.0))])),
      ),
    ]),
  }
  store.save("s-rebuild", mutated)
  let second = match native_replay_index_for(cache, "s-rebuild", path) {
    Ok(index) => index
    Err(reason) => abort("metadata rebuild failed: " + reason)
  }
  assert_false(second.incremental)
  assert_eq(second.total, 7)
  assert_eq(replay_test_int(second.context, "tokens"), 13)
  // A truncating rewrite replaces the line table entirely.
  let short = @posoco_types.Session::{
    messages: [
      @kernel.Message::UserMessage(content=[@kernel.Content::Text("only")]),
    ],
    metadata: Map::from_array([]),
  }
  store.save("s-rebuild", short)
  let third = match native_replay_index_for(cache, "s-rebuild", path) {
    Ok(index) => index
    Err(reason) => abort("truncating rebuild failed: " + reason)
  }
  assert_false(third.incremental)
  assert_eq(third.total, 1)
  let page = native_replay_page_json(
    cache,
    "s-rebuild",
    path,
    third.revision,
    0,
    10,
    0,
  )
  assert_eq(
    replay_test_without_index(replay_test_items(page)[0]).stringify(),
    replay_test_items(transcript_json(short))[0].stringify(),
  )
  replay_test_teardown(root)
}

///|
/// A crash mid-append can leave a torn tail that *starts* like a zero-block
/// line (tool result / system prompt). The index pass only ever assembles such
/// a line's prefix, so registering it would claim a line the page cannot parse
/// and every page would then fail on recoverable data. The torn tail is
/// ignored: the journal replays exactly its fully persisted prefix.
async test "replay ignores torn zero-block tail lines" {
  let root = @fs.tmpdir(prefix="cetas-replay-torn-zero-")
  let ids : Array[String] = ["s-torn-tool", "s-torn-system"]
  // The two zero-block shapes: a tool result and a system prompt.
  let roles : Array[String] = ["tool", "system"]
  // Far more than one reader chunk, so the torn body spans many reads and the
  // zero-block shortcut (prefix recognised, body never assembled) is exercised.
  let body = "t".repeat(200 * 1024)
  let mut which = 0
  while which < roles.length() {
    let id = ids[which]
    let session = replay_test_session()
    let path = replay_test_save(root, id, session)
    let oracle_items = replay_test_items(transcript_json(session))
    @fs.write_file(
      path,
      "{\"role\":\"" +
      roles[which] +
      "\",\"content\":[{\"type\":\"text\",\"text\":\"" +
      body,
      append=true,
      create_mode=@fs.CreateMode::OpenExisting,
    ) catch {
      error => abort("torn zero-block append failed: " + error.to_string())
    }
    let size : Int64 = @fs.file_size(path) catch { _ => 0L }
    assert_true(size > REPLAY_CHUNK_BYTES.to_int64() * 2L)
    let cache = NativeReplayCache::new()
    let index = native_replay_index_json(cache, id, path, -1, 0)
    assert_eq(replay_test_error(index), "")
    assert_eq(replay_test_int(index, "total"), oracle_items.length())
    // The line table holds the metadata line plus the eight persisted message
    // lines; the torn tail must not appear as a ninth message line.
    let table = match native_replay_index_for(cache, id, path) {
      Ok(table) => table
      Err(reason) => abort("torn tail index failed: " + reason)
    }
    assert_eq(table.starts.length(), 9)
    assert_eq(table.firsts.length(), 9)
    let page = native_replay_page_json(cache, id, path, "", 0, 100, 0)
    assert_eq(replay_test_error(page), "")
    assert_eq(replay_test_int(page, "total"), oracle_items.length())
    let items = replay_test_items(page)
    assert_eq(items.length(), oracle_items.length())
    for position in 0..<items.length() {
      assert_eq(
        replay_test_without_index(items[position]).stringify(),
        oracle_items[position].stringify(),
      )
    }
    which += 1
  }
  replay_test_teardown(root)
}

///|
/// A crash during the metadata write leaves a torn *first* line, which has no
/// complete predecessor to recover to. The torn line is ignored, so the journal
/// projects as the empty session an untouched journal is, and the summary falls
/// back to the id title. A newline-terminated malformed metadata line stays
/// explicit corruption: torn-tail recovery never invents a transcript.
async test "replay treats a torn metadata line as an empty journal" {
  let root = @fs.tmpdir(prefix="cetas-replay-torn-meta-")
  let torn_id = "s-torn-meta"
  let torn_path = @fs_session.jsonl_session_path(root, torn_id)
  @fs.write_file(torn_path, "{\"name\":\"Torn") catch {
    error => abort("torn metadata fixture failed: " + error.to_string())
  }
  let cache = NativeReplayCache::new()
  let index = native_replay_index_json(cache, torn_id, torn_path, -1, 0)
  assert_eq(replay_test_error(index), "")
  assert_eq(replay_test_int(index, "total"), 0)
  assert_eq(replay_test_items(index).length(), 0)
  let page = native_replay_page_json(cache, torn_id, torn_path, "", 0, 100, 0)
  assert_eq(replay_test_error(page), "")
  assert_eq(replay_test_int(page, "total"), 0)
  assert_eq(replay_test_items(page).length(), 0)
  assert_true(replay_test_field(page, "next") is Json::Null)
  let torn_summary = match native_replay_summary(torn_id, torn_path) {
    Ok(summary) => summary
    Err(reason) => abort("torn metadata must not fail the summary: " + reason)
  }
  assert_eq(torn_summary.title, torn_id)
  // Classic compatibility: a journal with nothing persisted yet is an empty
  // session, and the summary of an empty session is its id.
  let empty_id = "s-empty-journal"
  let empty_path = @fs_session.jsonl_session_path(root, empty_id)
  @fs.write_file(empty_path, "") catch {
    error => abort("empty journal fixture failed: " + error.to_string())
  }
  let empty_summary = match native_replay_summary(empty_id, empty_path) {
    Ok(summary) => summary
    Err(reason) => abort("empty journal summary failed: " + reason)
  }
  assert_eq(empty_summary.title, empty_id)
  let empty_index = native_replay_index_json(
    NativeReplayCache::new(),
    empty_id,
    empty_path,
    -1,
    0,
  )
  assert_eq(replay_test_error(empty_index), "")
  assert_eq(replay_test_int(empty_index, "total"), 0)
  // Terminated corruption is still reported, never silently dropped.
  @fs.write_file(
    torn_path,
    "{\"name\":\"Torn\n",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  ) catch {
    error => abort("corrupt metadata rewrite failed: " + error.to_string())
  }
  match native_replay_summary(torn_id, torn_path) {
    Ok(summary) =>
      abort("terminated malformed metadata produced a title: " + summary.title)
    Err(reason) =>
      assert_true(reason.contains("malformed session summary metadata line"))
  }
  let corrupt = native_replay_index_json(
    NativeReplayCache::new(),
    torn_id,
    torn_path,
    -1,
    0,
  )
  assert_true(
    replay_test_error(corrupt).contains("malformed transcript metadata line"),
  )
  replay_test_teardown(root)
}

///|
/// Append-only growth must stay append-only when the appended bytes end in a
/// torn tail: the extension accepts the complete appended lines, ignores the
/// torn one (so the new tool call truthfully stays `running`), and a later
/// append that completes the line rebuilds into the settled result. At no point
/// is a partial line reported as a result.
async test "replay extension ignores a torn tail and settles it once complete" {
  let root = @fs.tmpdir(prefix="cetas-replay-extend-torn-")
  let id = "s-extend-torn"
  let path = replay_test_save(root, id, replay_test_session())
  let cache = NativeReplayCache::new()
  let first = match native_replay_index_for(cache, id, path) {
    Ok(index) => index
    Err(reason) => abort("initial index failed: " + reason)
  }
  assert_eq(first.total, 7)
  let body = "t".repeat(200 * 1024)
  let call_line = "{\"role\":\"assistant\",\"content\":[]," +
    "\"tool_calls\":[{\"id\":\"c-tail\",\"name\":\"read\",\"arguments\":{}}]," +
    "\"finish_reason\":\"tool_calls\"}\n"
  let result_prefix = "{\"role\":\"tool\",\"content\":[{\"type\":\"text\",\"text\":\""
  @fs.write_file(
    path,
    call_line + result_prefix + body,
    append=true,
    create_mode=@fs.CreateMode::OpenExisting,
  ) catch {
    error => abort("torn append failed: " + error.to_string())
  }
  let grown = match native_replay_index_for(cache, id, path) {
    Ok(index) => index
    Err(reason) => abort("append extension over a torn tail failed: " + reason)
  }
  // The complete appended call is indexed; the torn result line is not, so the
  // table grows by exactly one message line (metadata + 8 + 1).
  assert_true(grown.incremental)
  assert_eq(grown.total, 8)
  assert_eq(grown.starts.length(), 10)
  assert_eq(grown.firsts.length(), 10)
  let pending_page = native_replay_page_json(cache, id, path, "", 0, 100, 0)
  assert_eq(replay_test_error(pending_page), "")
  let pending_items = replay_test_items(pending_page)
  assert_eq(pending_items.length(), 8)
  assert_eq(replay_test_string(pending_items[7], "kind"), "tool")
  assert_eq(replay_test_string(pending_items[7], "callId"), "c-tail")
  // No fabricated outcome: a torn result is not a result.
  assert_eq(replay_test_string(pending_items[7], "status"), "running")
  assert_eq(replay_test_string(pending_items[7], "result"), "")
  // Completing the torn line invalidates the append-only prefix and rebuilds
  // into the exact persisted transcript.
  let tail = "end-of-body\"}]," +
    "\"tool_call_id\":\"c-tail\",\"name\":\"read\"}\n"
  @fs.write_file(
    path,
    tail,
    append=true,
    create_mode=@fs.CreateMode::OpenExisting,
  ) catch {
    error => abort("completion append failed: " + error.to_string())
  }
  let healed = match native_replay_index_for(cache, id, path) {
    Ok(index) => index
    Err(reason) => abort("completion rebuild failed: " + reason)
  }
  assert_false(healed.incremental)
  assert_eq(healed.total, 8)
  let healed_page = native_replay_page_json(cache, id, path, "", 0, 100, 0)
  assert_eq(replay_test_error(healed_page), "")
  let healed_items = replay_test_items(healed_page)
  assert_eq(healed_items.length(), 8)
  assert_eq(replay_test_string(healed_items[7], "status"), "done")
  assert_eq(replay_test_string(healed_items[7], "result"), body + "end-of-body")
  replay_test_teardown(root)
}

///|
/// The zero-block shortcut must key on the line's own top-level role, not on
/// the first bytes that happen to contain `"role":"tool"`. A foreign writer may
/// order the message keys differently and tool-call arguments (or a reasoning
/// payload) are nested JSON that can carry an unescaped `"role":"tool"` key
/// early in the line. Treating that as a tool result would drop the assistant's
/// tool call and shift every later absolute block index.
async test "replay role detection ignores nested role keys in arguments" {
  let root = @fs.tmpdir(prefix="cetas-replay-nested-role-")
  let id = "s-nested-role"
  let path = @fs_session.jsonl_session_path(root, id)
  let jsonl = "{\"name\":\"Nested\"}\n" +
    "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"go\"}]}\n" +
    "{\"reasoning_raw\":{\"role\":\"tool\"},\"content\":[],\"tool_calls\":[{\"id\":\"c\",\"name\":\"x\",\"arguments\":{}}],\"role\":\"assistant\"}\n" +
    "{\"role\":\"tool\",\"content\":[{\"type\":\"text\",\"text\":\"done\"}],\"tool_call_id\":\"c\",\"name\":\"x\"}\n"
  @fs.write_file(path, jsonl) catch {
    error => abort("nested role fixture failed: " + error.to_string())
  }
  // The classic reader accepts the same journal, so it is the oracle here.
  let session = match @fs_session.session_from_jsonl(jsonl) {
    Ok(session) => session
    Err(_) => abort("classic reader rejected the nested-role fixture")
  }
  let oracle_items = replay_test_items(transcript_json(session))
  assert_eq(oracle_items.length(), 2)
  let cache = NativeReplayCache::new()
  let page = native_replay_page_json(cache, id, path, "", 0, 100, 0)
  assert_eq(replay_test_error(page), "")
  assert_eq(replay_test_int(page, "total"), oracle_items.length())
  let items = replay_test_items(page)
  assert_eq(items.length(), oracle_items.length())
  for position in 0..<items.length() {
    assert_eq(replay_test_int(items[position], "index"), position)
    assert_eq(
      replay_test_without_index(items[position]).stringify(),
      oracle_items[position].stringify(),
    )
  }
  assert_eq(replay_test_string(items[1], "kind"), "tool")
  assert_eq(replay_test_string(items[1], "status"), "done")
  replay_test_teardown(root)
}
