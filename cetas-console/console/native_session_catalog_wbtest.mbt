///|
/// Whitebox tests for the lightweight native session catalog. The fixtures are
/// real `<home>/.cetas/sessions/<bucket>/<id>.jsonl` trees, so the tests
/// exercise the disk scan, stat metadata, bounded title/cwd reads and paging
/// without constructing a runtime or a workspace.

///|
fn cat_test_field(json : Json, key : String) -> Json {
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
fn cat_test_string(json : Json, key : String) -> String {
  match cat_test_field(json, key) {
    Json::String(value) => value
    _ => abort("expected string field " + key)
  }
}

///|
fn cat_test_string_or_null(json : Json, key : String) -> String? {
  match cat_test_field(json, key) {
    Json::String(value) => Some(value)
    Json::Null => None
    _ => abort("expected string-or-null field " + key)
  }
}

///|
fn cat_test_int64(json : Json, key : String) -> Int64 {
  match cat_test_field(json, key) {
    Json::Number(value, ..) => value.to_int64()
    _ => abort("expected numeric field " + key)
  }
}

///|
fn cat_test_int(json : Json, key : String) -> Int32 {
  match cat_test_field(json, key) {
    Json::Number(value, ..) => value.to_int()
    _ => abort("expected integer field " + key)
  }
}

///|
fn cat_test_bool(json : Json, key : String) -> Bool {
  match cat_test_field(json, key) {
    Json::True => true
    Json::False => false
    _ => abort("expected boolean field " + key)
  }
}

///|
fn cat_test_items(json : Json) -> Array[Json] {
  match cat_test_field(json, "items") {
    Json::Array(items) => items
    _ => abort("expected an items array")
  }
}

///|
fn cat_test_warnings(json : Json) -> Array[Json] {
  match cat_test_field(json, "warnings") {
    Json::Array(items) => items
    Json::Null => []
    _ => abort("expected a warnings array")
  }
}

///|
fn cat_test_error(json : Json) -> String {
  match cat_test_field(json, "error") {
    Json::String(value) => value
    _ => ""
  }
}

///|
fn cat_test_find(items : Array[Json], bucket : String, id : String) -> Json? {
  for item in items {
    if cat_test_string(item, "bucket") == bucket &&
      cat_test_string(item, "id") == id {
      return Some(item)
    }
  }
  None
}

///|
fn cat_test_metadata(title : String?, cwd : String?) -> Map[String, Json] {
  let fields : Map[String, Json] = Map::from_array([])
  match title {
    Some(value) => fields["posoco.title"] = Json::string(value)
    None => ()
  }
  match cwd {
    Some(value) =>
      fields[@fs_session.SESSION_CWD_METADATA_KEY] = Json::string(value)
    None => ()
  }
  fields
}

///|
async fn cat_test_mkdir(path : String) -> Unit {
  let exists = @fs.exists(path) catch { _ => false }
  if exists {
    return
  }
  @fs.mkdir(path, recursive=true) catch {
    error => abort("mkdir " + path + " failed: " + error.to_string())
  }
}

///|
async fn cat_test_home(tag : String) -> String {
  @fs.tmpdir(prefix="cetas-native-catalog-" + tag + "-")
}

///|
async fn cat_test_cleanup(root : String) -> Unit {
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
/// Write `<home>/.cetas/sessions/<bucket>/<id>.jsonl` with the metadata line
/// plus an optional legacy user line, exactly in the fs-session JSONL shape.
async fn cat_test_write_session(
  home : String,
  bucket : String,
  id : String,
  metadata : Map[String, Json],
  user_text : String?,
) -> String {
  let dir = @fs_session.project_sessions_root(home) + "/" + bucket
  cat_test_mkdir(dir)
  let mut content = Json::object(metadata).stringify() + "\n"
  match user_text {
    Some(text) =>
      content = content +
        Json::object(
          Map::from_array([
            ("role", Json::string("user")),
            (
              "content",
              Json::array([
                Json::object(
                  Map::from_array([
                    ("type", Json::string("text")),
                    ("text", Json::string(text)),
                  ]),
                ),
              ]),
            ),
          ]),
        ).stringify() +
        "\n"
    None => ()
  }
  let path = dir + "/" + id + ".jsonl"
  @fs.write_file(path, content) catch {
    error => abort("write session " + path + " failed: " + error.to_string())
  }
  path
}

///|
fn cat_test_modified_ms(mtime : (Int64, Int32)) -> Int64 {
  mtime.0 * 1000L + mtime.1.to_int64() / 1_000_000L
}

///|
async test "native session catalog current scope lists the active bucket from disk" {
  let home = cat_test_home("current")
  let cwd_a = "/work/alpha"
  let cwd_b = "/work/beta"
  let bucket_a = @fs_session.project_dir_name(cwd_a)
  let bucket_b = @fs_session.project_dir_name(cwd_b)
  let orphan_bucket = "session_orphan_0123456789ab"
  let id_a = "2026-10-01T10-00-00-000Z_aaaaaaa1"
  let id_b = "2026-10-02T10-00-00-000Z_bbbbbbb2"
  let id_orphan = "2026-10-03T10-00-00-000Z_ccccccc3"
  let path_a = cat_test_write_session(
    home,
    bucket_a,
    id_a,
    cat_test_metadata(Some("Alpha one"), Some(cwd_a)),
    Some("alpha turn"),
  )
  @async.sleep(20)
  let _ = cat_test_write_session(
    home,
    bucket_b,
    id_b,
    cat_test_metadata(Some("Beta one"), Some(cwd_b)),
    Some("beta turn"),
  )
  @async.sleep(20)
  let _ = cat_test_write_session(
    home,
    orphan_bucket,
    id_orphan,
    cat_test_metadata(Some("Orphan one"), None),
    None,
  )
  // Non-bucket directories and non-jsonl files are not rows.
  cat_test_mkdir(@fs_session.project_sessions_root(home) + "/notes")
  @fs.write_file(
    @fs_session.project_sessions_root(home) + "/notes/ignored.jsonl",
    "{}",
  ) catch {
    error => abort("notes fixture failed: " + error.to_string())
  }
  @fs.write_file(
    @fs_session.project_sessions_root(home) + "/" + bucket_a + "/ignored.txt",
    "not a session",
  ) catch {
    error => abort("text fixture failed: " + error.to_string())
  }

  let page = native_session_catalog_json(home, cwd_a, id_a, "current", "", 50)
  assert_eq(cat_test_error(page), "")
  assert_eq(cat_test_string(page, "scope"), "current")
  assert_eq(cat_test_string(page, "cwd"), cwd_a)
  assert_eq(cat_test_int(page, "total"), 1)
  assert_eq(cat_test_field(page, "next"), Json::null())
  let items = cat_test_items(page)
  assert_eq(items.length(), 1)
  let row = items[0]
  assert_eq(cat_test_string(row, "id"), id_a)
  assert_eq(cat_test_string(row, "bucket"), bucket_a)
  assert_eq(cat_test_string(row, "title"), "Alpha one")
  assert_eq(cat_test_string_or_null(row, "cwd"), Some(cwd_a))
  assert_eq(cat_test_string(row, "folder"), @fs_session.bucket_slug(bucket_a))
  assert_true(cat_test_bool(row, "current"))
  assert_true(cat_test_bool(row, "resumable"))
  assert_eq(cat_test_field(row, "reason"), Json::null())
  // Disk truth, not a registry projection.
  let expected_size : Int64 = @fs.file_size(path_a) catch { _ => -1L }
  let expected_mtime = @fs.mtime(path_a) catch { _ => (0L, 0) }
  assert_eq(cat_test_int64(row, "sizeBytes"), expected_size)
  assert_eq(
    cat_test_int64(row, "modifiedAt"),
    cat_test_modified_ms(expected_mtime),
  )
  assert_true(expected_size > 0L)
  // A literal epoch-milliseconds range (2020..2100): a seconds or
  // microseconds regression in the unit conversion fails here even though
  // the formula-mirror assertion above cannot see it.
  assert_true(cat_test_int64(row, "modifiedAt") > 1_577_836_800_000L)
  assert_true(cat_test_int64(row, "modifiedAt") < 4_102_444_800_000L)

  // A current scope for a project with no bucket is empty, not an error.
  let missing = native_session_catalog_json(
    home, "/work/never-written", "", "current", "", 50,
  )
  assert_eq(cat_test_error(missing), "")
  assert_eq(cat_test_int(missing, "total"), 0)
  assert_eq(cat_test_items(missing).length(), 0)

  // All scope mixes every bucket, including one no runtime ever registered.
  let all = native_session_catalog_json(home, cwd_a, id_a, "all", "", 50)
  assert_eq(cat_test_error(all), "")
  assert_eq(cat_test_string(all, "scope"), "all")
  assert_eq(cat_test_int(all, "total"), 3)
  let all_items = cat_test_items(all)
  assert_eq(all_items.length(), 3)
  let mut previous = 9223372036854775807L
  for item in all_items {
    let modified = cat_test_int64(item, "modifiedAt")
    assert_true(modified <= previous)
    previous = modified
  }
  // The unregistered bucket is found by the disk walk, not a registry.
  match cat_test_find(all_items, orphan_bucket, id_orphan) {
    Some(row) => {
      assert_eq(cat_test_string(row, "folder"), "orphan")
      assert_eq(cat_test_string_or_null(row, "cwd"), None)
      assert_true(!cat_test_bool(row, "current"))
      // Foreign and no recorded folder: explicitly not resumable.
      assert_true(!cat_test_bool(row, "resumable"))
    }
    None => abort("all scope lost the unregistered bucket row")
  }

  let beta = cat_test_find(all_items, bucket_b, id_b)
  match beta {
    Some(row) => {
      assert_eq(cat_test_string(row, "title"), "Beta one")
      assert_eq(cat_test_string_or_null(row, "cwd"), Some(cwd_b))
      assert_true(cat_test_bool(row, "resumable"))
    }
    None => abort("all scope lost the beta bucket row")
  }
  assert_true(cat_test_find(all_items, "notes", "ignored") is None)
  // The explicit deadline spelling of the default scope is still `current`.
  let defaulted = native_session_catalog_json(
    home, cwd_a, id_a, "default", "", 50,
  )
  assert_eq(cat_test_string(defaulted, "scope"), "current")
  assert_eq(cat_test_int(defaulted, "total"), 1)
  // The empty scope is the picker's built-in default.
  let empty_scope = native_session_catalog_json(home, cwd_a, id_a, "", "", 50)
  assert_eq(cat_test_string(empty_scope, "scope"), "current")
  assert_eq(cat_test_int(empty_scope, "total"), 1)
  cat_test_cleanup(home)
}

///|
async test "native session catalog keeps one id distinct across project buckets" {
  let home = cat_test_home("duplicate")
  let cwd_a = "/work/project-a"
  let cwd_b = "/work/project-b"
  let bucket_a = @fs_session.project_dir_name(cwd_a)
  let bucket_b = @fs_session.project_dir_name(cwd_b)
  let shared_id = "2026-10-05T10-00-00-000Z_dup00001"
  let _ = cat_test_write_session(
    home,
    bucket_b,
    shared_id,
    cat_test_metadata(Some("Beta copy"), Some(cwd_b)),
    None,
  )
  @async.sleep(20)
  let _ = cat_test_write_session(
    home,
    bucket_a,
    shared_id,
    cat_test_metadata(Some("Alpha copy"), Some(cwd_a)),
    None,
  )
  let page = native_session_catalog_json(home, cwd_a, shared_id, "all", "", 50)
  assert_eq(cat_test_error(page), "")
  let items = cat_test_items(page)
  assert_eq(cat_test_int(page, "total"), 2)
  assert_eq(items.length(), 2)
  // The same id is two rows, keyed by bucket.
  let alpha = cat_test_find(items, bucket_a, shared_id)
  let beta = cat_test_find(items, bucket_b, shared_id)
  match (alpha, beta) {
    (Some(alpha), Some(beta)) => {
      assert_eq(cat_test_string(alpha, "title"), "Alpha copy")
      assert_eq(cat_test_string(beta, "title"), "Beta copy")
      // Current needs both the bucket and the id to match.
      assert_true(cat_test_bool(alpha, "current"))
      assert_true(!cat_test_bool(beta, "current"))
      assert_true(cat_test_bool(alpha, "resumable"))
      assert_true(cat_test_bool(beta, "resumable"))
    }
    _ => abort("duplicate ids must remain two addressable rows")
  }
  // Equal timestamps fall back to the stable (bucket, id) identity order.
  let left : NativeSessionCatalogCandidate = {
    bucket: "session_beta_0123456789ab",
    id: "same-id",
    path: "",
    size_bytes: 0L,
    modified_ms: 1000L,
  }
  let right : NativeSessionCatalogCandidate = {
    bucket: "session_alpha_0123456789ab",
    id: "same-id",
    path: "",
    size_bytes: 0L,
    modified_ms: 1000L,
  }
  assert_eq(native_session_catalog_compare(left, right), 1)
  assert_eq(native_session_catalog_compare(right, left), -1)
  assert_eq(native_session_catalog_compare(left, left), 0)
  let newer : NativeSessionCatalogCandidate = {
    bucket: "session_alpha_0123456789ab",
    id: "other-id",
    path: "",
    size_bytes: 0L,
    modified_ms: 2000L,
  }
  assert_eq(native_session_catalog_compare(newer, left), -1)
  cat_test_cleanup(home)
}

///|
async test "native session catalog explains legacy current and foreign rows" {
  let home = cat_test_home("legacy")
  let cwd_a = "/work/mine"
  let cwd_b = "/work/other"
  let bucket_a = @fs_session.project_dir_name(cwd_a)
  let bucket_b = @fs_session.project_dir_name(cwd_b)
  let current_legacy = "2026-10-01T10-00-00-000Z_legacy01"
  let foreign_legacy = "2026-10-02T10-00-00-000Z_legacy02"
  let foreign_modern = "2026-10-03T10-00-00-000Z_modern03"
  let _ = cat_test_write_session(
    home,
    bucket_a,
    current_legacy,
    // No `cetas.cwd`, exactly like journals written before the contract.
    cat_test_metadata(Some("Mine old"), None),
    Some("mine old turn"),
  )
  @async.sleep(20)
  let _ = cat_test_write_session(
    home,
    bucket_b,
    foreign_legacy,
    cat_test_metadata(None, None),
    // Legacy first-user title fallback: normalized and whitespace-collapsed.
    Some("  hello   world  "),
  )
  @async.sleep(20)
  let _ = cat_test_write_session(
    home,
    bucket_b,
    foreign_modern,
    cat_test_metadata(Some("Other new"), Some(cwd_b)),
    None,
  )
  let page = native_session_catalog_json(
    home, cwd_a, current_legacy, "all", "", 50,
  )
  assert_eq(cat_test_error(page), "")
  let items = cat_test_items(page)
  assert_eq(items.length(), 3)
  match cat_test_find(items, bucket_a, current_legacy) {
    Some(row) => {
      assert_eq(cat_test_string(row, "title"), "Mine old")
      assert_eq(cat_test_string_or_null(row, "cwd"), None)
      assert_true(cat_test_bool(row, "current"))
      // The active bucket is known even when the row is legacy: resumable.
      assert_true(cat_test_bool(row, "resumable"))
      assert_eq(cat_test_field(row, "reason"), Json::null())
    }
    None => abort("current legacy row disappeared")
  }
  match cat_test_find(items, bucket_b, foreign_legacy) {
    Some(row) => {
      assert_eq(cat_test_string(row, "title"), "hello world")
      assert_eq(cat_test_string_or_null(row, "cwd"), None)
      assert_true(!cat_test_bool(row, "current"))
      // A foreign legacy row has no knowable directory: explicitly not
      // resumable, never a silent guess from the bucket name.
      assert_true(!cat_test_bool(row, "resumable"))
      assert_true(
        cat_test_string(row, "reason").contains("no project folder recorded"),
      )
    }
    None => abort("foreign legacy row was silently dropped")
  }
  match cat_test_find(items, bucket_b, foreign_modern) {
    Some(row) => assert_true(cat_test_bool(row, "resumable"))
    None => abort("foreign modern row was silently dropped")
  }
  cat_test_cleanup(home)
}

///|
async test "native session catalog surfaces corruption, skips, bad scopes and root I/O" {
  let home = cat_test_home("corrupt")
  let cwd = "/work/corrupt"
  let bucket = @fs_session.project_dir_name(cwd)
  let corrupt_id = "2026-10-04T10-00-00-000Z_corrupt1"
  let dir = @fs_session.project_sessions_root(home) + "/" + bucket
  cat_test_mkdir(dir)
  @fs.write_file(dir + "/" + corrupt_id + ".jsonl", "{not json}\n") catch {
    error => abort("corrupt fixture failed: " + error.to_string())
  }
  // A `.jsonl` name that is not a regular file is skipped with a warning, not
  // silently omitted.
  cat_test_mkdir(dir + "/ghost.jsonl")
  // A bucket-shaped directory with an unsafe name is reported, not joined.
  cat_test_mkdir(
    @fs_session.project_sessions_root(home) + "/session_bad%2fescape",
  )
  let page = native_session_catalog_json(
    home, cwd, corrupt_id, "current", "", 50,
  )
  assert_eq(cat_test_error(page), "")
  let items = cat_test_items(page)
  // The corrupt journal is still a row with a recognizable title and reason.
  assert_eq(items.length(), 1)
  let row = items[0]
  assert_eq(cat_test_string(row, "id"), corrupt_id)
  assert_eq(cat_test_string(row, "title"), corrupt_id)
  assert_eq(cat_test_string_or_null(row, "cwd"), None)
  assert_true(cat_test_bool(row, "current"))
  assert_true(!cat_test_bool(row, "resumable"))
  assert_true(cat_test_string(row, "reason").contains("corrupt session"))
  let warnings = cat_test_warnings(page)
  let mut saw_corrupt = false
  let mut saw_ghost = false
  let mut saw_bucket = false
  for warning in warnings {
    let kind = cat_test_string(warning, "kind")
    if kind == "corrupt" &&
      cat_test_string_or_null(warning, "id") == Some(corrupt_id) {
      saw_corrupt = true
    } else if kind == "not-a-file" &&
      cat_test_string_or_null(warning, "id") == Some("ghost") {
      saw_ghost = true
    } else if kind == "invalid-bucket" &&
      cat_test_string_or_null(warning, "bucket") == Some("session_bad%2fescape") {
      saw_bucket = true
    }
  }
  assert_true(saw_corrupt)
  assert_true(saw_ghost)
  // The unsafe bucket name is only visited by the all scope: current only
  // opens the active bucket by construction.
  let all_page = native_session_catalog_json(
    home, cwd, corrupt_id, "all", "", 50,
  )
  assert_eq(cat_test_error(all_page), "")
  for warning in cat_test_warnings(all_page) {
    if cat_test_string(warning, "kind") == "invalid-bucket" &&
      cat_test_string_or_null(warning, "bucket") == Some("session_bad%2fescape") {
      saw_bucket = true
    }
  }
  assert_true(saw_bucket)

  // Unknown scopes are caller errors, never a silent widening to all.
  let invalid = native_session_catalog_json(
    home, cwd, corrupt_id, "bogus", "", 50,
  )
  assert_true(cat_test_error(invalid).contains("scope"))

  // Missing root: empty catalog, no error.
  let missing_home = cat_test_home("missing-root")
  let missing = native_session_catalog_json(
    missing_home, cwd, corrupt_id, "all", "", 50,
  )
  assert_eq(cat_test_error(missing), "")
  assert_eq(cat_test_int(missing, "total"), 0)
  assert_eq(cat_test_items(missing).length(), 0)

  // Empty root: empty catalog, no error. Distinct from a root shape error.
  let empty_home = cat_test_home("empty-root")
  cat_test_mkdir(@fs_session.project_sessions_root(empty_home))
  let empty = native_session_catalog_json(
    empty_home, cwd, corrupt_id, "all", "", 50,
  )
  assert_eq(cat_test_error(empty), "")
  assert_eq(cat_test_int(empty, "total"), 0)

  // Root exists but is a file: explicit I/O/shape error, not "no sessions".
  let bad_home = cat_test_home("file-root")
  cat_test_mkdir(bad_home + "/.cetas")
  @fs.write_file(@fs_session.project_sessions_root(bad_home), "not a directory") catch {
    error => abort("file root fixture failed: " + error.to_string())
  }
  let broken = native_session_catalog_json(
    bad_home, cwd, corrupt_id, "all", "", 50,
  )
  assert_true(cat_test_error(broken).contains("not a directory"))
  cat_test_cleanup(bad_home)
  cat_test_cleanup(empty_home)
  cat_test_cleanup(missing_home)
  cat_test_cleanup(home)
}

///|
async test "native session catalog pages by keyset anchor and caps at 200 rows" {
  let home = cat_test_home("paging")
  let cwd = "/work/many"
  let bucket = @fs_session.project_dir_name(cwd)
  let expected : Array[String] = []
  for index = 0; index < 205; index = index + 1 {
    let id = "s-" + index.to_string()
    expected.push(id)
    let _ = cat_test_write_session(
      home,
      bucket,
      id,
      cat_test_metadata(Some("Session " + id), None),
      None,
    )
  }
  let first = native_session_catalog_json(home, cwd, "", "all", "", 0)
  assert_eq(cat_test_error(first), "")
  assert_eq(cat_test_string(first, "scope"), "all")
  assert_eq(cat_test_int(first, "total"), 205)
  assert_eq(cat_test_items(first).length(), 200)
  // The continuation is an opaque keyset anchor, not a row offset.
  let anchor = cat_test_string_or_null(first, "next")
  assert_true(anchor is Some(_))
  assert_true(
    @utf8.encode(first.stringify()).length() <= NATIVE_SESSION_CATALOG_MAX_BYTES,
  )
  let second = native_session_catalog_json(
    home,
    cwd,
    "",
    "all",
    anchor.unwrap_or(""),
    0,
  )
  assert_eq(cat_test_error(second), "")
  assert_eq(cat_test_items(second).length(), 5)
  assert_eq(cat_test_field(second, "next"), Json::null())
  let seen : Map[String, Bool] = Map::from_array([])
  for page in [first, second] {
    for row in cat_test_items(page) {
      let id = cat_test_string(row, "id")
      assert_true(!seen.contains(id)) // keyset pages never repeat a row
      seen[id] = true
    }
  }
  assert_eq(seen.length(), 205)
  for id in expected {
    assert_true(seen.contains(id))
  }
  // Anchoring at the newest row serves everything except that row: appending
  // a journal while the picker is open cannot duplicate it on a later page.
  let newest = cat_test_items(first)[0]
  let newest_anchor = Json::array([
    Json::number(cat_test_int64(newest, "modifiedAt").to_double()),
    Json::string(cat_test_string(newest, "bucket")),
    Json::string(cat_test_string(newest, "id")),
  ]).stringify()
  let tail = native_session_catalog_json(home, cwd, "", "all", newest_anchor, 0)
  assert_eq(cat_test_error(tail), "")
  let tail_ids : Array[String] = []
  for row in cat_test_items(tail) {
    tail_ids.push(cat_test_string(row, "id"))
  }
  // The remaining rows minus the newest one, still under the 200-row cap.
  assert_eq(tail_ids.length(), 200)
  assert_true(!tail_ids.contains(cat_test_string(newest, "id")))
  // A malformed cursor is a caller error, never page 0 in disguise.
  let invalid = native_session_catalog_json(home, cwd, "", "all", "garbage", 50)
  assert_true(cat_test_error(invalid).contains("cursor"))
  cat_test_cleanup(home)
}

///|
async test "native session catalog degrades a failed legacy title scan without corrupting the row" {
  let home = cat_test_home("degraded")
  let cwd = "/work/degraded"
  let bucket = @fs_session.project_dir_name(cwd)
  let id = "2026-10-06T10-00-00-000Z_degrade1"
  let dir = @fs_session.project_sessions_root(home) + "/" + bucket
  cat_test_mkdir(dir)
  // Metadata line parses and records the project directory; the legacy
  // first-user scan then hits a malformed terminated line. Only the title may
  // degrade — the row is still resumable.
  @fs.write_file(
    dir + "/" + id + ".jsonl",
    Json::object(cat_test_metadata(None, Some(cwd))).stringify() +
    "\n{not json}\n",
  ) catch {
    error => abort("degraded fixture failed: " + error.to_string())
  }
  let page = native_session_catalog_json(home, cwd, id, "current", "", 50)
  assert_eq(cat_test_error(page), "")
  let items = cat_test_items(page)
  assert_eq(items.length(), 1)
  let row = items[0]
  assert_eq(cat_test_string(row, "id"), id)
  assert_eq(cat_test_string(row, "title"), id)
  assert_eq(cat_test_string_or_null(row, "cwd"), Some(cwd))
  assert_true(cat_test_bool(row, "resumable"))
  assert_eq(cat_test_field(row, "reason"), Json::null())
  let mut saw_degraded = false
  for warning in cat_test_warnings(page) {
    if cat_test_string(warning, "kind") == "title-degraded" {
      saw_degraded = true
    }
    assert_true(cat_test_string(warning, "kind") != "corrupt")
  }
  assert_true(saw_degraded)
  cat_test_cleanup(home)
}

///|
async test "native session catalog reports unreadable sessions without calling them corrupt" {
  let home = cat_test_home("unreadable")
  let cwd_a = "/work/readable"
  let cwd_b = "/work/sealed"
  let bucket_a = @fs_session.project_dir_name(cwd_a)
  let bucket_b = @fs_session.project_dir_name(cwd_b)
  let id_a = "2026-10-07T10-00-00-000Z_readabl1"
  let id_b = "2026-10-08T10-00-00-000Z_sealed01"
  let _ = cat_test_write_session(
    home,
    bucket_a,
    id_a,
    cat_test_metadata(Some("Readable"), Some(cwd_a)),
    None,
  )
  let sealed_path = cat_test_write_session(
    home,
    bucket_b,
    id_b,
    cat_test_metadata(Some("Sealed"), Some(cwd_b)),
    None,
  )
  @fs.chmod(sealed_path, 0o000) catch {
    error => abort("chmod fixture failed: " + error.to_string())
  }
  let page = native_session_catalog_json(home, cwd_a, id_a, "all", "", 50)
  assert_eq(cat_test_error(page), "")
  let items = cat_test_items(page)
  assert_eq(items.length(), 2)
  match cat_test_find(items, bucket_b, id_b) {
    Some(row) => {
      // The stat-based row stays visible with its size/mtime.
      assert_true(cat_test_int64(row, "sizeBytes") > 0L)
      assert_eq(cat_test_string(row, "title"), id_b)
      // Same-bucket resume never needed the metadata, so it stays possible;
      // a foreign unreadable row has no readable target directory.
      assert_true(!cat_test_bool(row, "resumable"))
      assert_true(cat_test_string(row, "reason").contains("unreadable"))
    }
    None => abort("unreadable row disappeared")
  }
  let mut saw_unreadable = false
  for warning in cat_test_warnings(page) {
    if cat_test_string(warning, "kind") == "unreadable" {
      saw_unreadable = true
    }
    assert_true(cat_test_string(warning, "kind") != "corrupt")
  }
  assert_true(saw_unreadable)
  @fs.chmod(sealed_path, 0o644) catch {
    _ => ()
  }
  cat_test_cleanup(home)
}

///|
async test "native session catalog keeps the wire under one MiB with wide rows" {
  let home = cat_test_home("wire")
  let cwd = "/work/wide"
  let bucket = @fs_session.project_dir_name(cwd)
  // Paths with characters JSON must escape make each row several kilobytes;
  // 160 of them exceed the page byte budget long before the row cap.
  let wide_cwd = "C:" + "\\".repeat(4000)
  for index = 0; index < 160; index = index + 1 {
    let id = "wide-" + index.to_string()
    let _ = cat_test_write_session(
      home,
      bucket,
      id,
      cat_test_metadata(Some("Wide " + id), Some(wide_cwd)),
      None,
    )
  }
  let page = native_session_catalog_json(home, cwd, "", "all", "", 0)
  assert_eq(cat_test_error(page), "")
  assert_eq(cat_test_int(page, "total"), 160)
  let items = cat_test_items(page)
  assert_true(items.length() > 0)
  assert_true(items.length() < 160)
  // The byte-budget stop still hands back a continuation anchor, and the
  // anchor's page is disjoint from the truncated one.
  let anchor = cat_test_string_or_null(page, "next")
  assert_true(anchor is Some(_))
  let follow = native_session_catalog_json(
    home,
    cwd,
    "",
    "all",
    anchor.unwrap_or(""),
    0,
  )
  assert_eq(cat_test_error(follow), "")
  let first_ids : Map[String, Bool] = Map::from_array([])
  for row in items {
    first_ids[cat_test_string(row, "id")] = true
  }
  for row in cat_test_items(follow) {
    assert_true(!first_ids.contains(cat_test_string(row, "id")))
  }
  assert_true(
    @utf8.encode(page.stringify()).length() <= NATIVE_SESSION_CATALOG_MAX_BYTES,
  )
  for row in items {
    match cat_test_string_or_null(row, "cwd") {
      Some(value) =>
        assert_true(value.length() <= NATIVE_SESSION_CATALOG_MAX_CWD_CHARS)
      None => abort("wide cwd row lost its recorded folder")
    }
  }
  cat_test_cleanup(home)
}
