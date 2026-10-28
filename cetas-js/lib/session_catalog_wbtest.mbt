///|
/// session_catalog_wbtest.mbt — whitebox tests for the cross-project session
/// catalog that backs the `/sessions` "All" view.

///|
/// Isolated home per call: a fresh /tmp directory so the catalog walk never
/// touches the developer's real `~/.cetas`.
fn catalog_test_home(tag : String) -> String {
  let unique = js_random_uuid(node_random_uuid)
  "/tmp/cetas-js-session-catalog-" + tag + "-" + unique
}

///|
async fn catalog_test_cleanup(home : String) -> Unit {
  let fs = @workspace.JsWorkspaceFs()
  fs.remove(home) catch {
    _ => ()
  }
}

///|
/// Create `<home>/.cetas/sessions/<bucket>/<id>.jsonl` with the given
/// metadata line; returns the full path of the written session file.
async fn write_catalog_session(
  home : String,
  bucket : String,
  id : String,
  metadata : Map[String, Json],
) -> String {
  let fs = @workspace.JsWorkspaceFs()
  let dir = @fs_session.project_sessions_root(home) + "/" + bucket
  fs.mkdir(dir, recursive=true) catch {
    _ => fail("mkdir for bucket failed")
  }
  let jsonl = Json::object(metadata).stringify() +
    "\n" +
    Json::object(
      Map::from_array([
        ("role", Json::string("user")),
        (
          "content",
          Json::array([
            Json::object(
              Map::from_array([
                ("type", Json::string("text")),
                ("text", Json::string("hello")),
              ]),
            ),
          ]),
        ),
      ]),
    ).stringify() +
    "\n"
  let path = dir + "/" + id + ".jsonl"
  fs.write_file(path, jsonl) catch {
    _ => fail("write session failed")
  }
  path
}

///|
fn catalog_entries(raw : String) -> Array[Json] raise {
  match @json.parse(raw) {
    Json::Array(items) => items
    _ => fail("catalog must be a JSON array")
  }
}

///|
fn catalog_field(entry : Json, key : String) -> Json raise {
  match entry {
    Json::Object(fields) =>
      match fields.get(key) {
        Some(value) => value
        None => fail("catalog entry is missing " + key)
      }
    _ => fail("catalog entry must be an object")
  }
}

///|
fn catalog_string(entry : Json, key : String) -> String raise {
  match catalog_field(entry, key) {
    Json::String(value) => value
    _ => fail("catalog field " + key + " must be a string")
  }
}

///|
async test "catalog lists every project bucket with its recorded cwd" {
  let home = catalog_test_home("all")
  let cwd_a = "/work/project-a"
  let cwd_b = "/work/project-b"
  let bucket_a = @fs_session.project_dir_name(cwd_a)
  let bucket_b = @fs_session.project_dir_name(cwd_b)
  let path_a = write_catalog_session(
    home,
    bucket_a,
    "2026-10-01T10-00-00-000Z_aaaaaaa1",
    Map::from_array([
      ("posoco.title", Json::string("Alpha work")),
      (@fs_session.SESSION_CWD_METADATA_KEY, Json::string(cwd_a)),
    ]),
  )
  let _ = write_catalog_session(
    home,
    bucket_b,
    "2026-10-02T10-00-00-000Z_bbbbbbb2",
    Map::from_array([
      ("posoco.title", Json::string("Beta work")),
      (@fs_session.SESSION_CWD_METADATA_KEY, Json::string(cwd_b)),
    ]),
  )
  let entries = catalog_entries(session_catalog_json(home))
  assert_eq(entries.length(), 2)
  let expected_dir = @fs_session.project_sessions_root(home) + "/" + bucket_a
  let mut saw_a = false
  let mut saw_b = false
  for entry in entries {
    let bucket = catalog_string(entry, "bucket")
    if bucket == bucket_a {
      saw_a = true
      assert_eq(catalog_string(entry, "cwd"), cwd_a)
      assert_eq(catalog_string(entry, "folder"), "project-a")
      assert_eq(catalog_string(entry, "dir"), expected_dir)
      assert_eq(catalog_string(entry, "title"), "Alpha work")
    } else if bucket == bucket_b {
      saw_b = true
      assert_eq(catalog_string(entry, "cwd"), cwd_b)
      assert_eq(catalog_string(entry, "folder"), "project-b")
    }
  }
  assert_true(saw_a)
  assert_true(saw_b)
  // The written file is exactly where the catalog says it is.
  assert_true(
    path_a.has_suffix(expected_dir + "/2026-10-01T10-00-00-000Z_aaaaaaa1.jsonl"),
  )
  catalog_test_cleanup(home)
}

///|
async test "catalog keeps legacy sessions with a null cwd and the bucket slug" {
  let home = catalog_test_home("legacy")
  let _ = write_catalog_session(
    home,
    "session_legacy_0123456789ab",
    "2026-10-03T10-00-00-000Z_ccccccc3",
    // No `cetas.cwd`: written before the metadata contract existed.
    Map::from_array([("posoco.title", Json::string("Old work"))]),
  )
  let entries = catalog_entries(session_catalog_json(home))
  assert_eq(entries.length(), 1)
  assert_eq(catalog_field(entries[0], "cwd"), Json::null())
  assert_eq(catalog_string(entries[0], "folder"), "legacy")
  assert_eq(catalog_string(entries[0], "title"), "Old work")
  catalog_test_cleanup(home)
}

///|
async test "catalog ignores non-bucket directories and a missing root" {
  let home = catalog_test_home("missing")
  // Nothing created yet: no sessions root at all.
  assert_eq(catalog_entries(session_catalog_json(home)).length(), 0)
  let fs = @workspace.JsWorkspaceFs()
  fs.mkdir(@fs_session.project_sessions_root(home) + "/notes", recursive=true) catch {
    _ => fail("mkdir failed")
  }
  assert_eq(catalog_entries(session_catalog_json(home)).length(), 0)
  catalog_test_cleanup(home)
}

///|
async test "catalog skips a corrupt session instead of blanking the list" {
  let home = catalog_test_home("corrupt")
  let bucket = @fs_session.project_dir_name("/work/good")
  let _ = write_catalog_session(
    home,
    bucket,
    "2026-10-04T10-00-00-000Z_ddddddd4",
    Map::from_array([
      ("posoco.title", Json::string("Good session")),
      (@fs_session.SESSION_CWD_METADATA_KEY, Json::string("/work/good")),
    ]),
  )
  let corrupt = write_catalog_session(
    home,
    bucket,
    "2026-10-05T10-00-00-000Z_eeeeeee5",
    Map::from_array([]),
  )
  let fs = @workspace.JsWorkspaceFs()
  fs.write_file(corrupt, "not json\n") catch {
    _ => fail("rewrite failed")
  }
  let entries = catalog_entries(session_catalog_json(home))
  assert_eq(entries.length(), 1)
  assert_eq(catalog_string(entries[0], "title"), "Good session")
  catalog_test_cleanup(home)
}
