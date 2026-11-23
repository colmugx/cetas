///|
/// session_all_roundtrip_wbtest.mbt — independent acceptance round trip for the
/// `/sessions` "All" view.
///
/// The unit tests around this feature verify the metadata helpers and the
/// catalog separately. This suite checks the join instead: a session written
/// through the exact store composition the JS host uses must be persisted with
/// its project directory, and the cross-project catalog must report back
/// precisely that directory — never a guess derived from the bucket name.

///|
fn all_roundtrip_home(tag : String) -> String {
  "/tmp/cetas-js-all-roundtrip-" + tag + "-" + js_random_uuid(node_random_uuid)
}

///|
async fn all_roundtrip_cleanup(home : String) -> Unit {
  @workspace.JsWorkspaceFs().remove(home) catch {
    _ => ()
  }
}

///|
async fn all_roundtrip_rows(home : String) -> Array[Json] {
  match @json.parse(session_catalog_json(home)) {
    Json::Array(rows) => rows
    _ => fail("session catalog must be a JSON array")
  }
}

///|
fn all_roundtrip_row(rows : Array[Json], id : String) -> Json raise {
  for row in rows {
    if row is Json::Object(fields) {
      match fields.get("id") {
        Some(Json::String(value)) if value == id => return row
        _ => ()
      }
    }
  }
  fail("catalog is missing session " + id)
}

///|
fn all_roundtrip_field(row : Json, key : String) -> Json raise {
  match row {
    Json::Object(fields) =>
      match fields.get(key) {
        Some(value) => value
        None => fail("catalog row is missing " + key)
      }
    _ => fail("catalog row must be a JSON object")
  }
}

///|
fn all_roundtrip_str(row : Json, key : String) -> String raise {
  match all_roundtrip_field(row, key) {
    Json::String(value) => value
    _ => fail("catalog field " + key + " must be a string")
  }
}

///|
/// A catalog row's `cwd`: `Some(path)` when the session recorded one, `None`
/// when the row carries JSON null (legacy journal).
fn all_roundtrip_cwd(row : Json) -> String? raise {
  match all_roundtrip_field(row, "cwd") {
    Json::String(value) if !value.is_empty() => Some(value)
    Json::Null => None
    other => fail("cwd must be a string or null, got " + other.stringify())
  }
}

///|
async test "acceptance: a persisted session records its cwd and the catalog reports it back" {
  let home = all_roundtrip_home("bound")
  defer @async.protect_from_cancel(() => all_roundtrip_cleanup(home))
  let cwd = "/work/alpha"
  let id = "2026-10-10T09-00-00-000Z_ab12cd34"
  let dir = @fs_session.project_sessions_dir(home, cwd)
  // Composed exactly like the JS host store (cetas-js/lib/cetas_js.mbt): the
  // bucket directory plus the project cwd, normalized.
  let store = @fs_session.JsonlSessionStore(
    dir,
    cwd=Some(@fs_session.normalize_cwd(cwd)),
  )
  // A brand-new session's first persist is an append, not a save.
  store.append_messages(id, 0, [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("first turn")]),
  ]) catch {
    e => fail("append failed: \{e}")
  }
  // 1) The persisted metadata line itself carries the directory: this is the
  //    precondition the whole "All" view stands on.
  let raw = @workspace.JsWorkspaceFs().read_file(dir + "/" + id + ".jsonl") catch {
    _ => fail("could not read the persisted session")
  }
  assert_true(raw.contains("\"cetas.cwd\""))
  assert_true(raw.contains("/work/alpha"))
  // 2) The catalog reports that same directory, the bucket and the slug.
  let rows = all_roundtrip_rows(home) catch {
    e => fail("catalog failed: \{e}")
  }
  assert_eq(rows.length(), 1)
  let row = all_roundtrip_row(rows, id)
  assert_eq(all_roundtrip_cwd(row), Some("/work/alpha"))
  assert_eq(all_roundtrip_str(row, "folder"), "alpha")
  assert_eq(all_roundtrip_str(row, "dir"), dir)
  assert_eq(all_roundtrip_str(row, "title"), "first turn")
}

///|
async test "acceptance: a journal without a recorded cwd is visible but never guessed" {
  let home = all_roundtrip_home("legacy")
  defer @async.protect_from_cancel(() => all_roundtrip_cleanup(home))
  let legacy_id = "2026-10-11T09-00-00-000Z_00ff00ff"
  // A bucket whose slug spells a path the session never recorded. If the
  // catalog ever derived a cwd from the bucket name, this row would look
  // cross-resumable and the picker could silently reopen the wrong folder.
  let bucket = "session_ghost_0123456789ab"
  let dir = @fs_session.project_sessions_root(home) + "/" + bucket
  let fs = @workspace.JsWorkspaceFs()
  fs.mkdir(dir, recursive=true) catch {
    _ => fail("could not create the legacy bucket")
  }
  fs.write_file(
    dir + "/" + legacy_id + ".jsonl",
    "{\"posoco.title\":\"Legacy work\"}\n" +
    "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"old turn\"}]}\n",
  ) catch {
    _ => fail("could not write the legacy journal")
  }
  let rows = all_roundtrip_rows(home) catch {
    e => fail("catalog failed: \{e}")
  }
  assert_eq(rows.length(), 1)
  let row = all_roundtrip_row(rows, legacy_id)
  // Visible in the All list…
  assert_eq(all_roundtrip_str(row, "folder"), "ghost")
  assert_eq(all_roundtrip_str(row, "title"), "Legacy work")
  // …but the directory stays unknown, so the picker must refuse to cross over.
  assert_eq(all_roundtrip_cwd(row), None)
}

///|
async test "acceptance: corruption never hides the healthy projects or their cwds" {
  let home = all_roundtrip_home("mixed")
  defer @async.protect_from_cancel(() => all_roundtrip_cleanup(home))
  let fs = @workspace.JsWorkspaceFs()
  let good_dir = @fs_session.project_sessions_dir(home, "/work/beta")
  fs.mkdir(good_dir, recursive=true) catch {
    _ => fail("could not create the good bucket")
  }
  fs.write_file(
    good_dir + "/2026-10-12T09-00-00-000Z_11223344.jsonl",
    "{\"cetas.cwd\":\"/work/beta\",\"posoco.title\":\"Beta work\"}\n" +
    "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"beta turn\"}]}\n",
  ) catch {
    _ => fail("could not write the good session")
  }
  let other_dir = @fs_session.project_sessions_dir(home, "/work/gamma")
  fs.mkdir(other_dir, recursive=true) catch {
    _ => fail("could not create the second bucket")
  }
  fs.write_file(
    "\{other_dir}/2026-10-13T09-00-00-000Z_33445566.jsonl",
    (
      #|{"cetas.cwd":"/work/gamma","posoco.title":"Gamma work"}
      #|{"role":"user","content":[{"type":"text","text":"gamma turn"}]}
      #|
    ),
  ) catch {
    _ => fail("could not write the second session")
  }
  // A correctly named journal outside a project bucket must not leak in.
  let non_bucket = "\{@fs_session.project_sessions_root(home)}/notes"
  fs.mkdir(non_bucket, recursive=true) catch {
    _ => fail("could not create the notes directory")
  }
  fs.write_file(
    "\{non_bucket}/2026-10-14T09-00-00-000Z_55667788.jsonl",
    (
      #|{"posoco.title":"Not a project session"}
      #|{"role":"user","content":[{"type":"text","text":"do not list"}]}
      #|
    ),
  ) catch {
    _ => fail("could not write the non-bucket journal")
  }
  // A corrupt neighbor in a real project bucket must not blank the catalog.
  fs.write_file(
    "\{good_dir}/2026-10-15T09-00-00-000Z_99887766.jsonl",
    "not a journal\n",
  ) catch {
    _ => fail("could not write the broken session")
  }
  let rows = all_roundtrip_rows(home) catch {
    e => fail("catalog failed: \{e}")
  }
  @debug.assert_eq(rows.length(), 2)
  let beta = all_roundtrip_row(rows, "2026-10-12T09-00-00-000Z_11223344")
  let gamma = all_roundtrip_row(rows, "2026-10-13T09-00-00-000Z_33445566")
  @debug.assert_eq(all_roundtrip_str(beta, "dir"), good_dir)
  @debug.assert_eq(all_roundtrip_cwd(beta), Some("/work/beta"))
  @debug.assert_eq(all_roundtrip_str(gamma, "dir"), other_dir)
  @debug.assert_eq(all_roundtrip_cwd(gamma), Some("/work/gamma"))
}

///|
async test "acceptance: a first run without a sessions root lists nothing" {
  let home = all_roundtrip_home("empty")
  defer @async.protect_from_cancel(() => all_roundtrip_cleanup(home))
  let rows = all_roundtrip_rows(home) catch {
    e => fail("catalog failed: \{e}")
  }
  assert_eq(rows.length(), 0)
}
