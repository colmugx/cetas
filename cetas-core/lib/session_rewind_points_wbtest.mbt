///|
fn rewind_points_meta() -> String {
  Json::object(
    Map::from_array([
      ("format", Json::string("cetas-session")),
      ("version", Json::number(1)),
    ]),
  ).stringify()
}

///|
fn rewind_points_user(text : String) -> String {
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
  ).stringify()
}

///|
fn rewind_points_assistant(text : String) -> String {
  Json::object(
    Map::from_array([
      ("role", Json::string("assistant")),
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
  ).stringify()
}

///|
test "persisted rewind points preserve physical JSONL addressing" {
  let jsonl = [
    rewind_points_meta(),
    rewind_points_user("before the gap"),
    "{not valid json",
    "",
    rewind_points_assistant("survivor"),
    rewind_points_user("after the gap"),
  ].join("\n")
  let points = list_persisted_rewind_points(jsonl)
  assert_eq(points.length(), 2)
  assert_eq(points[0].message_index, 0)
  assert_eq(points[0].preview, "before the gap")
  assert_eq(points[1].message_index, 4)
  assert_eq(points[1].preview, "after the gap")
}

///|
test "persisted rewind previews flatten text and preserve image presence" {
  let image_only = Json::object(
    Map::from_array([
      ("role", Json::string("user")),
      (
        "content",
        Json::array([
          Json::object(
            Map::from_array([
              ("type", Json::string("image")),
              ("media_type", Json::string("image/png")),
              ("data", Json::string("AAAA")),
            ]),
          ),
        ]),
      ),
    ]),
  ).stringify()
  let mixed = Json::object(
    Map::from_array([
      ("role", Json::string("user")),
      (
        "content",
        Json::array([
          Json::object(
            Map::from_array([
              ("type", Json::string("text")),
              ("text", Json::string("what is in this")),
            ]),
          ),
          Json::object(
            Map::from_array([
              ("type", Json::string("image")),
              ("media_type", Json::string("image/png")),
              ("data", Json::string("AAAA")),
            ]),
          ),
        ]),
      ),
    ]),
  ).stringify()
  let jsonl = [
    rewind_points_meta(),
    rewind_points_user("line one\nline two\n\nline three"),
    image_only,
    mixed,
  ].join("\n")
  let points = list_persisted_rewind_points(jsonl)
  assert_eq(points.length(), 3)
  assert_eq(points[0].preview, "line one line two line three")
  assert_eq(points[1].preview, "(image)")
  assert_eq(points[2].preview, "what is in this (image)")
}

///|
test "persisted rewind previews are bounded and whitespace-only rows are skipped" {
  let long = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  let jsonl = [
    rewind_points_meta(),
    rewind_points_user("   "),
    rewind_points_user(long),
  ].join("\n")
  let points = list_persisted_rewind_points(jsonl)
  assert_eq(points.length(), 1)
  assert_eq(points[0].message_index, 1)
  assert_eq(points[0].preview.length(), 60)
  assert_true(points[0].preview.has_suffix("…"))
}

///|
test "synthetic user context occupies addresses but is not rewindable" {
  let jsonl = [
    rewind_points_meta(),
    rewind_points_user(
      " ## Memory\n\n<nmem-context type=\"memory\" trust=\"false\">…</nmem-context>",
    ),
    rewind_points_user("real prompt"),
    rewind_points_user(
      "<permission-context type=\"mode\" trust=\"true\">…</permission-context>",
    ),
    rewind_points_user("follow-up"),
  ].join("\n")
  let points = list_persisted_rewind_points(jsonl)
  assert_eq(points.length(), 2)
  assert_eq(points[0].message_index, 1)
  assert_eq(points[0].preview, "real prompt")
  assert_eq(points[1].message_index, 3)
  assert_eq(points[1].preview, "follow-up")

  assert_true(read_persisted_rewind_user_message(jsonl, 0) is None)
  assert_eq(read_persisted_rewind_user_message(jsonl, 1), Some("real prompt"))
  assert_true(read_persisted_rewind_user_message(jsonl, 2) is None)
}

///|
test "persisted rewind user refill uses the same physical address space" {
  let image_only = Json::object(
    Map::from_array([
      ("role", Json::string("user")),
      (
        "content",
        Json::array([
          Json::object(Map::from_array([("type", Json::string("image"))])),
        ]),
      ),
    ]),
  ).stringify()
  let jsonl = [
    rewind_points_meta(),
    rewind_points_user("line one\nline two"),
    "{bad",
    "",
    rewind_points_assistant("ok"),
    rewind_points_user("after"),
    image_only,
  ].join("\n")
  assert_eq(
    read_persisted_rewind_user_message(jsonl, 0),
    Some("line one\nline two"),
  )
  assert_true(read_persisted_rewind_user_message(jsonl, 1) is None)
  assert_true(read_persisted_rewind_user_message(jsonl, 2) is None)
  assert_true(read_persisted_rewind_user_message(jsonl, 3) is None)
  assert_eq(read_persisted_rewind_user_message(jsonl, 4), Some("after"))
  assert_eq(read_persisted_rewind_user_message(jsonl, 5), Some(""))
  assert_true(read_persisted_rewind_user_message(jsonl, 6) is None)
  assert_true(read_persisted_rewind_user_message(jsonl, -1) is None)
}
