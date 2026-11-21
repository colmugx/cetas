///|
async fn database_transcript_snapshot(
  backend : ConsoleSessionBackend,
  session_id : String,
) -> Result[(String, Json), String] {
  let before = match (backend.revision)(session_id) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let session = backend.catalog.load(session_id) catch {
    error => return Err(error.to_string())
  }
  let after = match (backend.revision)(session_id) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  if before != after {
    return Err("session changed during transcript read")
  }
  Ok((after, transcript_json(session)))
}

///|
fn database_transcript_items(projection : Json) -> (Array[Json], Json) {
  match projection {
    Json::Object(fields) =>
      match fields.get("items") {
        Some(Json::Array(items)) =>
          (items, fields.get("context").unwrap_or(Json::null()))
        _ => ([], Json::null())
      }
    _ => ([], Json::null())
  }
}

///|
fn database_transcript_item(
  original : Json,
  index : Int32,
  light : Bool,
) -> Json {
  let fields = match original {
    Json::Object(fields) => fields.copy()
    _ => Map([])
  }
  fields["index"] = replay_int_json(index)
  let kind = match fields.get("kind") {
    Some(Json::String(value)) => value
    _ => ""
  }
  if kind == "tool" {
    let args = fields.get("args").unwrap_or(Json::null())
    let result = match fields.get("result") {
      Some(Json::String(value)) => value
      _ => ""
    }
    if light {
      fields.remove("args")
      fields.remove("result")
      fields["argsBytes"] = replay_int_json(
        @utf8.encode(args.stringify()).length(),
      )
      fields["resultBytes"] = replay_int_json(@utf8.encode(result).length())
    } else {
      let args_bytes = @utf8.encode(args.stringify()).length()
      if args_bytes > REPLAY_INLINE_BYTES {
        fields["args"] = Json::null()
        fields["argsRef"] = replay_ref_json(index, "args", args_bytes)
      }
      let bytes = @utf8.encode(result).length()
      if bytes > REPLAY_INLINE_BYTES {
        fields["result"] = Json::string(replay_preview(result))
        fields["resultRef"] = replay_ref_json(index, "result", bytes)
      }
    }
  } else {
    let value = match fields.get("text") {
      Some(Json::String(value)) => value
      _ => ""
    }
    let bytes = @utf8.encode(value).length()
    if light {
      fields.remove("text")
      fields["textBytes"] = replay_int_json(bytes)
    } else if bytes > REPLAY_INLINE_BYTES {
      fields["text"] = Json::string(replay_preview(value))
      fields["textRef"] = replay_ref_json(index, "text", bytes)
    }
  }
  Json::object(fields)
}

///|
fn database_transcript_window(
  originals : Array[Json],
  first : Int32,
  limit : Int32,
  max_bytes : Int32,
  light : Bool,
) -> (Array[Json], Int32?) {
  let start = if first < 0 { 0 } else { first }
  let cap = if limit <= 0 {
    100
  } else if limit > REPLAY_PAGE_MAX_LIMIT {
    REPLAY_PAGE_MAX_LIMIT
  } else {
    limit
  }
  let byte_cap = if max_bytes <= 0 {
    REPLAY_PAGE_DEFAULT_BYTES
  } else if max_bytes > REPLAY_PAGE_MAX_BYTES {
    REPLAY_PAGE_MAX_BYTES
  } else {
    max_bytes
  }
  let items : Array[Json] = []
  let mut total_bytes = 0
  let mut cursor = start
  while cursor < originals.length() && items.length() < cap {
    let value = database_transcript_item(originals[cursor], cursor, light)
    let size = @utf8.encode(value.stringify()).length()
    if size > byte_cap {
      break
    }
    if total_bytes + size > byte_cap {
      break
    }
    items.push(value)
    total_bytes += size
    cursor += 1
  }
  (items, if cursor < originals.length() { Some(cursor) } else { None })
}

///|
async fn database_transcript_index_json(
  backend : ConsoleSessionBackend,
  session_id : String,
  first : Int32,
  limit : Int32,
) -> Json {
  let (revision, projection) = match
    database_transcript_snapshot(backend, session_id) {
    Ok(value) => value
    Err(reason) => return replay_error(reason)
  }
  let (originals, context) = database_transcript_items(projection)
  let window = if limit <= 0 { REPLAY_INDEX_WINDOW } else { limit }
  let window = if window > REPLAY_PAGE_MAX_LIMIT {
    REPLAY_PAGE_MAX_LIMIT
  } else {
    window
  }
  let start = if first >= 0 {
    first
  } else if originals.length() > window {
    originals.length() - window
  } else {
    0
  }
  let (items, _) = database_transcript_window(
    originals,
    start,
    window,
    REPLAY_PAGE_DEFAULT_BYTES,
    true,
  )
  Json::object({
    "session_id": Json::string(session_id),
    "revision": Json::string(revision),
    "total": replay_int_json(originals.length()),
    "first": replay_int_json(start),
    "context": context,
    "items": Json::array(items),
  })
}

///|
async fn database_transcript_page_json(
  backend : ConsoleSessionBackend,
  session_id : String,
  revision : String,
  first : Int32,
  limit : Int32,
  max_bytes : Int32,
) -> Json {
  let (current, projection) = match
    database_transcript_snapshot(backend, session_id) {
    Ok(value) => value
    Err(reason) => return replay_error(reason)
  }
  if !revision.is_empty() && revision != current {
    return Json::object({
      "error": Json::string("stale transcript revision"),
      "session_id": Json::string(session_id),
      "revision": Json::string(current),
    })
  }
  let (originals, _) = database_transcript_items(projection)
  let start = if first < 0 { 0 } else { first }
  let (items, next) = database_transcript_window(
    originals, start, limit, max_bytes, false,
  )
  Json::object({
    "session_id": Json::string(session_id),
    "revision": Json::string(current),
    "first": replay_int_json(start),
    "total": replay_int_json(originals.length()),
    "items": Json::array(items),
    "next": replay_optional_int_json(next),
  })
}

///|
async fn database_transcript_source_json(
  backend : ConsoleSessionBackend,
  session_id : String,
  revision : String,
  index : Int32,
  field : String,
  offset : Int32,
  length : Int32,
) -> Json {
  let (current, projection) = match
    database_transcript_snapshot(backend, session_id) {
    Ok(value) => value
    Err(reason) => return replay_error(reason)
  }
  if !revision.is_empty() && revision != current {
    return Json::object({
      "error": Json::string("stale transcript revision"),
      "session_id": Json::string(session_id),
      "revision": Json::string(current),
    })
  }
  let (items, _) = database_transcript_items(projection)
  if index < 0 || index >= items.length() {
    return replay_error("transcript block index out of range")
  }
  let original = match items[index] {
    Json::Object(fields) => fields
    _ => return replay_error("transcript block is not an object")
  }
  let kind = match original.get("kind") {
    Some(Json::String(kind)) => kind
    _ => ""
  }
  let selected = if field.is_empty() {
    if kind == "tool" {
      "result"
    } else {
      "text"
    }
  } else {
    field
  }
  let payload = match (selected, original.get(selected)) {
    ("text", Some(Json::String(value))) if kind != "tool" => value
    ("result", Some(Json::String(value))) if kind == "tool" => value
    ("args", Some(value)) if kind == "tool" => value.stringify()
    _ => return replay_error("invalid transcript source field")
  }
  let bytes = @utf8.encode(payload)
  let count = bytes.length()
  let mut start = if offset < 0 {
    0
  } else if offset > count {
    count
  } else {
    offset
  }
  while start < count && !replay_utf8_lead(bytes.unsafe_get(start)) {
    start += 1
  }
  let want = if length <= 0 {
    REPLAY_SOURCE_MAX_BYTES
  } else if length > REPLAY_SOURCE_MAX_BYTES {
    REPLAY_SOURCE_MAX_BYTES
  } else {
    length
  }
  let mut end = start + want
  if end > count {
    end = count
  }
  while end < count && !replay_utf8_lead(bytes.unsafe_get(end)) {
    end += 1
  }
  let data = @utf8.decode(bytes[start:end]) catch {
    _ => return replay_error("invalid UTF-8 transcript source")
  }
  Json::object({
    "session_id": Json::string(session_id),
    "revision": Json::string(current),
    "index": replay_int_json(index),
    "field": Json::string(if field.is_empty() { "auto" } else { field }),
    "offset": replay_int_json(start),
    "length": replay_int_json(end - start),
    "total_bytes": replay_int_json(count),
    "next": if end < count {
      replay_int_json(end)
    } else {
      Json::null()
    },
    "data": Json::string(data),
  })
}
