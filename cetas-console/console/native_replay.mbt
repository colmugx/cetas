///|
/// Bounded native-only transcript replay.
///
/// The shared `session_transcript` command replays a session by asking the
/// catalog for `load`, which materialises the whole journal (messages, tool
/// results, attachments) and then projects it into one `Json` array. A resume
/// of a multi-hundred-megabyte journal therefore allocates the whole session
/// and a second whole-transcript `Json` tree before the terminal draws its
/// first line.
///
/// This module is the storage boundary for the native host's long-session
/// plan: the persisted journal stays exactly the fs-session JSONL format
/// (metadata line + one message line per message), and replay reads it through
/// bounded async file chunks instead of `@fs.read_file`:
///
/// - a streaming pass builds a compact line table (byte offset, projected
///   block count per non-blank message line) and the absolute projected block
///   total, without ever materialising a `Session`;
/// - `transcript_page` seeks directly to the line holding the first requested
///   projected block and streams forward only until the page budget is met;
/// - `transcript_index` is the same projection in light mode: block kinds,
///   turn/call ids, tool status and payload byte lengths, never bodies;
/// - `transcript_source` serves one block's text/result payload in bounded byte
///   ranges, so a giant body reaches the UI as refs plus range chunks;
/// - native session summaries read the metadata line plus the first user line
///   for the legacy title fallback, never `load`.
///
/// One physical JSONL line is still parsed whole and is bounded by
/// `REPLAY_MAX_LINE_BYTES`; a line above that limit is an explicit error, never
/// a silent truncation. Torn tails (an unterminated final line left by a crash
/// mid-append) keep the fs-session recovery rule: the partial line is ignored,
/// while a malformed *terminated* line is reported as corruption.
const REPLAY_CHUNK_BYTES : Int32 = 64 * 1024

///|
const REPLAY_MAX_LINE_BYTES : Int32 = 32 * 1024 * 1024

///|
/// A text/result/args payload at or below this size rides inline in a page
/// item; anything larger is a preview plus a `*Ref` range descriptor.
const REPLAY_INLINE_BYTES : Int32 = 256 * 1024

///|
const REPLAY_PREVIEW_CHARS : Int32 = 512

///|
const REPLAY_PAGE_DEFAULT_LIMIT : Int32 = 100

///|
const REPLAY_PAGE_MAX_LIMIT : Int32 = 1000

///|
const REPLAY_PAGE_DEFAULT_BYTES : Int32 = 1024 * 1024

///|
/// One frame stays comfortably under the 4 MiB host limit even when a single
/// item carries its full inline payload allowance.
const REPLAY_PAGE_MAX_BYTES : Int32 = 3 * 1024 * 1024

///|
const REPLAY_INDEX_WINDOW : Int32 = 400

///|
const REPLAY_SOURCE_MAX_BYTES : Int32 = 1024 * 1024

///|
const REPLAY_CACHE_LIMIT : Int32 = 4

///|
const REPLAY_SUMMARY_CHUNK_BYTES : Int32 = 32 * 1024

///|
const REPLAY_SUMMARY_SCAN_BYTES : Int64 = 64 * 1024

///|
const REPLAY_SUMMARY_LINES : Int32 = 64

///|
/// Width of the anchored role prefix (`{"role":"system"` is the longest of the
/// two zero-block shapes). The role decision never needs more of the line.
const REPLAY_ROLE_PREFIX_BYTES : Int32 = 16

///|
fn replay_error(message : String) -> Json {
  Json::object(Map::from_array([("error", Json::string(message))]))
}

///|
fn replay_int_json(value : Int32) -> Json {
  Json::number(value.to_double())
}

///|
fn replay_optional_int_json(value : Int32?) -> Json {
  match value {
    Some(number) => replay_int_json(number)
    None => Json::null()
  }
}

///|
/// One physical JSONL line read through bounded chunks.
priv struct NativeReplayLine {
  start : Int64
  length : Int32
  terminated : Bool
  blank : Bool
  oversized : Bool
  /// The index pass recognised a zero-block role in the line prefix and skipped
  /// assembling the body; `text` is only the bounded prefix.
  body_skipped : Bool
  text : String
}

///|
/// Sequential, bounded file reader over one persisted journal. It owns a fixed
/// chunk buffer; only the line currently being assembled grows, and it stops
/// growing at `REPLAY_MAX_LINE_BYTES` (the line is then flagged oversized and
/// drained to its newline so the reader stays aligned).
priv struct NativeReplayReader {
  file : @fs.File
  size : Int64
  chunk : FixedArray[Byte]
  chunk_bytes : Bytes
  mut chunk_start : Int64
  mut chunk_len : Int32
  mut cursor : Int32
  mut loaded_end : Int64
  mut bytes_read : Int64
  mut line_no : Int32
  /// Index-pass mode: stop assembling a line as soon as its prefix proves it
  /// projects no blocks (tool result / system prompt), so a 500 MB journal's
  /// index pass copies kilobytes instead of hundreds of megabytes.
  mut skip_zero_block_bodies : Bool
}

///|
async fn NativeReplayReader::open(
  path : String,
  chunk_bytes~ : Int32,
) -> NativeReplayReader {
  let file = @fs.open(path, mode=@fs.Mode::ReadOnly)
  errdefer file.close()
  let size = file.size()
  let chunk = FixedArray::make(chunk_bytes, b'\x00')
  {
    file,
    size,
    chunk,
    chunk_bytes: chunk.unsafe_reinterpret_as_bytes(),
    chunk_start: 0L,
    chunk_len: 0,
    cursor: 0,
    loaded_end: 0L,
    bytes_read: 0L,
    line_no: 0,
    skip_zero_block_bodies: false,
  }
}

///|
/// Read the next chunk into the fixed buffer. Returns false at end of file.
async fn NativeReplayReader::fill(self : NativeReplayReader) -> Bool {
  if self.loaded_end >= self.size {
    self.chunk_len = 0
    self.cursor = 0
    return false
  }
  let capacity = self.chunk.length()
  let start = self.loaded_end
  let mut filled = 0
  while filled < capacity {
    let read = self.file.read_at(
      self.chunk,
      position=start + filled.to_int64(),
      offset=filled,
      len=capacity - filled,
    )
    if read <= 0 {
      break
    }
    filled += read
  }
  self.bytes_read += filled.to_int64()
  self.loaded_end = start + filled.to_int64()
  self.chunk_start = start
  self.chunk_len = filled
  self.cursor = 0
  if filled > 0 {
    true
  } else {
    self.loaded_end = self.size
    false
  }
}

///|
/// Position the reader at an absolute byte offset (a line boundary from the
/// line table). The next `next_line` call reads from there.
fn NativeReplayReader::seek(self : NativeReplayReader, offset : Int64) -> Unit {
  self.loaded_end = offset
  self.chunk_start = offset
  self.chunk_len = 0
  self.cursor = 0
}

///|
fn replay_line_blank(bytes : Bytes, length : Int32) -> Bool {
  for index in 0..<length {
    let byte = bytes.unsafe_get(index)
    if byte != b' ' && byte != b'\t' && byte != b'\r' {
      return false
    }
  }
  true
}

///|
/// Read one line. Blanks are returned as `blank` lines (the caller skips them,
/// exactly as `session_from_jsonl` does); the final unterminated line is
/// returned with `terminated = false` so the caller can apply the torn-tail
/// rule.
async fn NativeReplayReader::next_line(
  self : NativeReplayReader,
) -> NativeReplayLine? {
  if self.chunk_len == 0 && !self.fill() {
    return None
  }
  let start = self.chunk_start + self.cursor.to_int64()
  let mut acc = FixedArray::make(256, b'\x00')
  let mut acc_len = 0
  let mut total = 0
  let mut oversized = false
  let mut skip_body = false
  let mut role_checked = !self.skip_zero_block_bodies
  while true {
    if self.cursor >= self.chunk_len {
      if !self.fill() {
        if total == 0 {
          return None
        }
        let bytes = acc.unsafe_reinterpret_as_bytes()
        let text = @utf8.decode(bytes[0:acc_len]) catch { _ => "" }
        self.line_no += 1
        return Some({
          start,
          length: total,
          terminated: false,
          blank: replay_line_blank(bytes, acc_len),
          oversized,
          body_skipped: skip_body,
          text,
        })
      }
    }
    let mut newline = -1
    for index = self.cursor; index < self.chunk_len; index = index + 1 {
      if self.chunk[index] == b'\n' {
        newline = index
        break
      }
    }
    let segment_end = if newline >= 0 { newline } else { self.chunk_len }
    let segment_len = segment_end - self.cursor
    total += segment_len
    if skip_body && acc_len >= 64 {
      // Body already proven zero-block; only the newline matters from here.
    } else if !oversized {
      let room = REPLAY_MAX_LINE_BYTES - acc_len
      let mut keep = if segment_len <= room { segment_len } else { room }
      if skip_body && acc_len + keep > 64 {
        keep = 64 - acc_len
      }
      if keep > 0 {
        let needed = acc_len + keep
        if needed > acc.length() {
          let mut capacity = acc.length()
          while capacity < needed {
            capacity = capacity * 2
          }
          let grown = FixedArray::make(capacity, b'\x00')
          FixedArray::blit_from_bytes(
            grown,
            0,
            acc.unsafe_reinterpret_as_bytes(),
            0,
            acc_len,
          )
          acc = grown
        }
        FixedArray::blit_from_bytes(
          acc,
          acc_len,
          self.chunk_bytes,
          self.cursor,
          keep,
        )
        acc_len += keep
      }
      if segment_len > room {
        oversized = true
      }
    }
    // The decision needs the line's own leading bytes, assembled across chunk
    // boundaries: `{"role":"<zero-block role>"` is 14..16 ASCII bytes, so the
    // anchored check below is exact once that much is assembled.
    if !role_checked && acc_len >= REPLAY_ROLE_PREFIX_BYTES {
      let prefix = acc.unsafe_reinterpret_as_bytes()[0:REPLAY_ROLE_PREFIX_BYTES]
      let text = @utf8.decode(prefix) catch { _ => "" }
      if replay_prefix_zero_block(text) {
        skip_body = true
      }
      role_checked = true
    }
    if newline >= 0 {
      self.cursor = newline + 1
      let bytes = acc.unsafe_reinterpret_as_bytes()
      let text = @utf8.decode(bytes[0:acc_len]) catch { _ => "" }
      self.line_no += 1
      return Some({
        start,
        length: total,
        terminated: true,
        blank: replay_line_blank(bytes, acc_len),
        oversized,
        body_skipped: skip_body,
        text,
      })
    }
    self.cursor = self.chunk_len
  }
  None
}

///|
/// One projected content block of a message line. `Tool` blocks become the
/// transcript's tool item; text blocks become user/assistant/reasoning items.
priv enum NativeReplayBlock {
  Text(kind~ : String, text~ : String)
  Tool(call_id~ : String, name~ : String, args~ : Json)
}

///|
/// One parsed message line, projected with the same field rules the shared
/// `transcript_json` projection applies to loaded `@kernel.Message` values.
priv struct NativeReplayMessage {
  role : String
  text : String
  blocks : Array[NativeReplayBlock]
  call_id : String
  is_error : Bool
}

///|
fn replay_content_blocks(
  content : Array[Json],
) -> Result[Array[@kernel.Content], String] {
  let blocks : Array[@kernel.Content] = []
  for block in content {
    match block {
      Json::Object(fields) =>
        match fields.get("type") {
          Some(Json::String("text")) =>
            match fields.get("text") {
              Some(Json::String(text)) =>
                blocks.push(@kernel.Content::Text(text))
              _ => return Err("content text block without a text field")
            }
          Some(Json::String("image")) =>
            match (fields.get("media_type"), fields.get("data")) {
              (Some(Json::String(media)), Some(Json::String(data))) =>
                blocks.push(@kernel.Content::Image(media_type=media, data~))
              _ =>
                match (fields.get("url"), fields.get("mime")) {
                  (Some(Json::String(url)), Some(Json::String(mime))) =>
                    blocks.push(
                      @kernel.Content::Image(media_type=mime, data=url),
                    )
                  _ => return Err("content image block without media payload")
                }
            }
          _ => return Err("content block without a known type")
        }
      _ => return Err("content block is not a JSON object")
    }
  }
  Ok(blocks)
}

///|
fn replay_content_text(content : Array[@kernel.Content]) -> String {
  let builder = StringBuilder()
  let mut first = true
  for block in content {
    match block {
      @kernel.Content::Text(text) => {
        if first {
          first = false
        } else {
          builder.write_char('\n')
        }
        builder.write_string(text)
      }
      _ => ()
    }
  }
  builder.to_string()
}

///|
fn replay_contains_text(content : Array[@kernel.Content]) -> Bool {
  for block in content {
    match block {
      @kernel.Content::Text(text) => if text != "" { return true }
      _ => ()
    }
  }
  false
}

///|
/// Parse one tool-call array with the disk compatibility rules
/// (`id` or `call_id`, `name`, `arguments`) the fs-session reader applies.
fn replay_tool_calls(value : Json?) -> Result[Array[@kernel.ToolCall], String] {
  match value {
    Some(Json::Array(calls)) => {
      let parsed : Array[@kernel.ToolCall] = []
      for call in calls {
        match call {
          Json::Object(fields) => {
            let call_id = match fields.get("id") {
              Some(Json::String(id)) => Some(id)
              _ =>
                match fields.get("call_id") {
                  Some(Json::String(id)) => Some(id)
                  _ => None
                }
            }
            let name = match fields.get("name") {
              Some(Json::String(name)) => Some(name)
              _ => None
            }
            let arguments = fields.get("arguments")
            match (call_id, name, arguments) {
              (Some(id), Some(name), Some(arguments)) =>
                parsed.push(@kernel.ToolCall::{
                  call_id: @kernel.CallId::unchecked(id),
                  name: @kernel.ToolName::unchecked(name),
                  arguments,
                })
              _ => return Err("tool call without id, name and arguments")
            }
          }
          _ => return Err("tool call is not a JSON object")
        }
      }
      Ok(parsed)
    }
    Some(_) => Err("tool_calls is not an array")
    None => Ok([])
  }
}

///|
/// Project one parsed message line. This mirrors the field rules of
/// `transcript_json` in `transcript.mbt` (the replay oracle) but consumes the
/// persisted disk shape directly.
fn replay_parse_message(json : Json) -> Result[NativeReplayMessage, String] {
  let fields = match json {
    Json::Object(fields) => fields
    _ => return Err("message line is not a JSON object")
  }
  let role = match fields.get("role") {
    Some(Json::String(role)) => role
    _ => return Err("message line without a string role")
  }
  let content_json = match fields.get("content") {
    Some(Json::Array(content)) => content
    _ => return Err("message line without a content array")
  }
  let content = match replay_content_blocks(content_json) {
    Ok(content) => content
    Err(reason) => return Err(reason)
  }
  match role {
    "system" =>
      Ok({ role, text: "", blocks: [], call_id: "", is_error: false, })
    "user" => {
      let text = replay_content_text(content)
      let blocks : Array[NativeReplayBlock] = if text == "" {
        []
      } else {
        [NativeReplayBlock::Text(kind="user", text~)]
      }
      Ok({ role, text, blocks, call_id: "", is_error: false, })
    }
    "assistant" => {
      let text = replay_content_text(content)
      let reasoning = match fields.get("reasoning_content") {
        Some(Json::String(reasoning)) => Some(reasoning)
        _ => None
      }
      let calls = match replay_tool_calls(fields.get("tool_calls")) {
        Ok(calls) => calls
        Err(reason) => return Err(reason)
      }
      let blocks : Array[NativeReplayBlock] = []
      match reasoning {
        Some(reasoning) =>
          if reasoning != "" {
            blocks.push(
              NativeReplayBlock::Text(kind="reasoning", text=reasoning),
            )
          }
        None => ()
      }
      if text != "" {
        blocks.push(NativeReplayBlock::Text(kind="assistant", text~))
      }
      for call in calls {
        blocks.push(
          NativeReplayBlock::Tool(
            call_id=call.call_id.to_string(),
            name=call.name.to_string(),
            args=call.arguments,
          ),
        )
      }
      Ok({ role, text, blocks, call_id: "", is_error: false, })
    }
    "tool" => {
      let call_id = match fields.get("tool_call_id") {
        Some(Json::String(id)) => id
        _ => return Err("tool message without tool_call_id")
      }
      let is_error = match fields.get("is_error") {
        Some(Json::True) => true
        _ => false
      }
      // The fs-session reader keeps the first text block as the outcome text
      // and treats later blocks as attachments; the transcript projection
      // renders only that outcome text.
      let mut text = ""
      let mut first_text = true
      for block in content {
        match block {
          @kernel.Content::Text(value) =>
            if first_text {
              text = value
              first_text = false
            }
          _ => ()
        }
      }
      Ok({ role, text, blocks: [], call_id, is_error, })
    }
    _ => Err("message line with an unknown role: " + role)
  }
}

///|
/// Cheap zero-block hint for the streaming index pass. Only the line's own,
/// top-level `role` may decide the projection, and it is the first key of the
/// compact JSON the fs-session writer emits, so the check is an anchored prefix
/// of the line. Tool results and system prompts are the two shapes that grow
/// without contributing projected blocks, so skipping their parse keeps a
/// 500 MB journal's index pass IO-bound instead of parse-bound. The page path
/// still parses every line it returns, so structure is validated on access.
fn replay_prefix_zero_block(text : String) -> Bool {
  // A *substring* search would match a nested `"role":"tool"` key: tool-call
  // arguments and reasoning payloads are nested JSON written verbatim, so a
  // producer that orders the message keys differently can put one near the
  // start of the line and hide the real role further in.
  text.has_prefix("{\"role\":\"tool\"") ||
  text.has_prefix("{\"role\":\"system\"")
}

///|
/// Projected block count of one message line, without materialising text
/// bodies beyond what the JSON parse already allocated. Used by the streaming
/// index pass: the count is all paging needs, so tool result bodies are never
/// concatenated or re-serialised.
fn replay_block_count(json : Json) -> Result[Int32, String] {
  let fields = match json {
    Json::Object(fields) => fields
    _ => return Err("message line is not a JSON object")
  }
  let role = match fields.get("role") {
    Some(Json::String(role)) => role
    _ => return Err("message line without a string role")
  }
  let content_json = match fields.get("content") {
    Some(Json::Array(content)) => content
    _ => return Err("message line without a content array")
  }
  let content = match replay_content_blocks(content_json) {
    Ok(content) => content
    Err(reason) => return Err(reason)
  }
  match role {
    "system" => Ok(0)
    "user" => if replay_contains_text(content) { Ok(1) } else { Ok(0) }
    "assistant" => {
      let calls = match replay_tool_calls(fields.get("tool_calls")) {
        Ok(calls) => calls
        Err(reason) => return Err(reason)
      }
      let mut count = if replay_contains_text(content) { 1 } else { 0 }
      match fields.get("reasoning_content") {
        Some(Json::String(reasoning)) => if reasoning != "" { count += 1 }
        _ => ()
      }
      Ok(count + calls.length())
    }
    "tool" =>
      match fields.get("tool_call_id") {
        Some(Json::String(_)) => Ok(0)
        _ => Err("tool message without tool_call_id")
      }
    _ => Err("message line with an unknown role: " + role)
  }
}

///|
/// Compact index of one persisted journal: one entry per non-blank line
/// (metadata first) plus absolute projected-block prefix sums. It is the only
/// per-session state replay needs; pages and sources read the file again from
/// the recorded offsets instead of keeping messages in memory.
pub struct NativeReplayIndex {
  priv session_id : String
  priv path : String
  priv mut revision : String
  priv mut total : Int32
  priv context : Json
  priv starts : Array[Int64]
  priv firsts : Array[Int32]
  /// File size this line table was built from; appends extend from here.
  priv mut size : Int64
  /// Last bytes of the indexed prefix; an append-only extension verifies them
  /// before trusting the cached table (a truncate/rewrite invalidates it).
  priv mut anchor : Bytes
  /// First line of the journal (up to 8 KiB); metadata rewrites (the store's
  /// model-selection refresh) invalidate instead of silently keeping a stale
  /// `context`.
  priv meta_anchor : Bytes
  priv mut ended_with_newline : Bool
  /// True when this revision was produced by scanning only appended bytes.
  priv mut incremental : Bool
}

///|
/// Bounded random-access slice for prefix/anchor verification. Never reads a
/// whole journal; a missing/unreadable slice is empty (the caller treats that
/// as "anchor mismatch" and rebuilds).
async fn native_replay_read_slice(
  path : String,
  position : Int64,
  length : Int32,
) -> Bytes {
  if length <= 0 {
    return b""
  }
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return b""
  }
  let file = @fs.open(path, mode=@fs.Mode::ReadOnly) catch { _ => return b"" }
  defer file.close()
  let buffer = FixedArray::make(length, b'\x00')
  let mut read = 0
  while read < length {
    let got = file.read_at(
      buffer,
      position=position + read.to_int64(),
      offset=read,
      len=length - read,
    )
    if got <= 0 {
      break
    }
    read += got
  }
  buffer.unsafe_reinterpret_as_bytes()[0:read].to_owned()
}

///|
/// First-line anchor: up to 8 KiB or the newline, whichever comes first. A
/// metadata-only rewrite (selection refresh / rename) changes this and forces a
/// full rebuild; message lines never do.
async fn native_replay_meta_anchor(path : String) -> Bytes {
  let prefix = native_replay_read_slice(path, 0L, 8 * 1024)
  let mut end = prefix.length()
  for index in 0..<prefix.length() {
    if prefix.unsafe_get(index) == b'\n' {
      end = index + 1
      break
    }
  }
  prefix[0:end].to_owned()
}

///|
async fn native_replay_tail_anchor(path : String, size : Int64) -> Bytes {
  if size <= 0L {
    return b""
  }
  let length = if size > 64L { 64 } else { size.to_int() }
  native_replay_read_slice(path, size - length.to_int64(), length)
}

///|
async fn native_replay_ends_with_newline(path : String, size : Int64) -> Bool {
  if size <= 0L {
    return true
  }
  let last = native_replay_read_slice(path, size - 1L, 1)
  last.length() == 1 && last.unsafe_get(0) == b'\n'
}

///|
fn replay_bytes_equal(left : Bytes, right : Bytes) -> Bool {
  if left.length() != right.length() {
    return false
  }
  for index in 0..<left.length() {
    if left.unsafe_get(index) != right.unsafe_get(index) {
      return false
    }
  }
  true
}

///|
async fn native_replay_revision(path : String) -> String {
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return "missing"
  }
  let size = @fs.file_size(path) catch { _ => -1L }
  let mtime = @fs.mtime(path) catch { _ => (0L, 0) }
  size.to_string() + ":" + mtime.0.to_string() + ":" + mtime.1.to_string()
}

///|
/// Stream the journal and build the line table. Memory is the chunk buffer plus
/// the one line being parsed; no `Session` and no transcript `Json` tree is ever
/// built. A torn tail stops the scan at the last complete line; a malformed
/// terminated line is corruption and fails the build.
async fn native_replay_build_index(
  session_id : String,
  path : String,
  revision : String,
) -> Result[NativeReplayIndex, String] {
  let starts : Array[Int64] = []
  let firsts : Array[Int32] = []
  let mut total : Int32 = 0
  let mut context : Json = Json::null()
  let mut indexed_size : Int64 = 0L
  let exists = @fs.exists(path) catch { _ => false }
  if exists {
    let reader = NativeReplayReader::open(path, chunk_bytes=REPLAY_CHUNK_BYTES) catch {
      error => return Err("cannot open transcript: " + error.to_string())
    }
    defer reader.file.close()
    indexed_size = reader.size
    // Line 0 of the table is the metadata line; it projects no blocks.
    let mut metadata : Map[String, Json] = Map([])
    while true {
      match reader.next_line() {
        None => {
          // An empty journal is an empty transcript, not an error.
          firsts.push(0)
          break
        }
        Some(line) =>
          if line.blank {
            continue
          } else if !line.terminated && line.oversized {
            // A crash mid-append can leave a huge partial first line; without a
            // terminating newline it is a torn tail, not corruption.
            firsts.push(0)
            break
          } else if line.oversized {
            return Err(
              "transcript metadata line exceeds " +
              REPLAY_MAX_LINE_BYTES.to_string() +
              " bytes",
            )
          } else {
            let parsed : Json = @json.parse(line.text) catch {
              error =>
                if !line.terminated {
                  // A torn first line is the crash-during-metadata-write shape:
                  // there is no earlier line to recover to, so the partial line
                  // is ignored and the journal is the empty session an
                  // untouched one is.
                  firsts.push(0)
                  break
                } else {
                  return Err(
                    "malformed transcript metadata line: " + error.to_string(),
                  )
                }
            }
            metadata = match parsed {
              Json::Object(fields) => fields
              _ => return Err("transcript metadata line is not a JSON object")
            }
            match metadata.get("posoco.context_state") {
              Some(value) => context = value
              None => ()
            }
            starts.push(0L)
            firsts.push(0)
            break
          }
      }
    }
    reader.skip_zero_block_bodies = true
    while true {
      match reader.next_line() {
        None => break
        Some(line) =>
          if line.blank {
            continue
          } else if !line.terminated &&
            (
              line.body_skipped ||
              line.oversized ||
              replay_prefix_zero_block(line.text)
            ) {
            // A torn tail is never indexed when its body was not validated: the
            // zero-block shortcut leaves `text` at the line prefix and an
            // oversized line is only drained. Registering such a line would
            // claim a line the page path then has to parse and fail on, so the
            // partial line is ignored like every other torn tail.
            break
          } else if line.body_skipped {
            starts.push(line.start)
            firsts.push(total)
          } else if line.oversized {
            return Err(
              "transcript line " +
              reader.line_no.to_string() +
              " exceeds " +
              REPLAY_MAX_LINE_BYTES.to_string() +
              " bytes; replay is bounded per line",
            )
          } else if replay_prefix_zero_block(line.text) {
            // Zero-block lines never need their body parsed during indexing.
            starts.push(line.start)
            firsts.push(total)
          } else {
            let parsed : Json = @json.parse(line.text) catch {
              error =>
                if !line.terminated {
                  break
                } else {
                  return Err(
                    "malformed transcript line " +
                    reader.line_no.to_string() +
                    ": " +
                    error.to_string(),
                  )
                }
            }
            match replay_block_count(parsed) {
              Ok(count) => {
                starts.push(line.start)
                firsts.push(total)
                total += count
              }
              Err(reason) =>
                if !line.terminated {
                  break
                } else {
                  return Err(
                    "malformed transcript line " +
                    reader.line_no.to_string() +
                    ": " +
                    reason,
                  )
                }
            }
          }
      }
    }
  } else {
    starts.push(0L)
    firsts.push(0)
  }
  let anchor = native_replay_tail_anchor(path, indexed_size)
  let meta_anchor = native_replay_meta_anchor(path)
  let ended_with_newline = native_replay_ends_with_newline(path, indexed_size)
  Ok({
    session_id,
    path,
    revision,
    total,
    context,
    starts,
    firsts,
    size: indexed_size,
    anchor,
    meta_anchor,
    ended_with_newline,
    incremental: false,
  })
}

///|
/// Extend a cached line table over an append-only journal. The store appends
/// JSONL lines under `append_messages`; a live long session therefore changes
/// the revision on every turn. A full re-index would re-read hundreds of
/// megabytes per turn, so an extension is accepted only when the indexed prefix
/// is provably unchanged:
///
/// - the file only grew (truncation/rewrite invalidates);
/// - the old tail bytes and the metadata line still match their anchors;
/// - the old prefix ended on a newline (no torn tail to merge into).
///
/// On success only the appended bytes are scanned; on any mismatch the caller
/// falls back to a full rebuild. Absolute block indexes of existing turns never
/// move, so a page opened against the old table stays valid.
async fn native_replay_extend_index(
  cached : NativeReplayIndex,
  path : String,
  revision : String,
) -> Result[NativeReplayIndex, String] {
  if cached.size <= 0L || cached.path != path {
    return Err("cached index has no appendable prefix")
  }
  if !cached.ended_with_newline {
    return Err("cached index ended mid-line")
  }
  let size = @fs.file_size(path) catch {
    _ => return Err("cannot stat transcript for append extension")
  }
  if size < cached.size {
    return Err("transcript shrank")
  }
  if !replay_bytes_equal(native_replay_meta_anchor(path), cached.meta_anchor) {
    return Err("transcript metadata changed")
  }
  if !replay_bytes_equal(
      native_replay_tail_anchor(path, cached.size),
      cached.anchor,
    ) {
    return Err("transcript prefix changed")
  }
  if size == cached.size {
    // Same bytes, new mtime (touch / selection-only metadata rewrite caught
    // above): refresh the revision without rescanning messages.
    cached.revision = revision
    return Ok(cached)
  }
  let reader = NativeReplayReader::open(path, chunk_bytes=REPLAY_CHUNK_BYTES) catch {
    error => return Err("cannot open transcript: " + error.to_string())
  }
  defer reader.file.close()
  reader.seek(cached.size)
  reader.line_no = cached.starts.length()
  reader.skip_zero_block_bodies = true
  let new_starts : Array[Int64] = []
  let new_firsts : Array[Int32] = []
  let mut total = cached.total
  while true {
    match reader.next_line() {
      None => break
      Some(line) =>
        if line.blank {
          continue
        } else if !line.terminated &&
          (
            line.body_skipped ||
            line.oversized ||
            replay_prefix_zero_block(line.text)
          ) {
          // Same torn-tail rule as the full build: a line whose body was never
          // validated is only registered once it is complete, so an append that
          // stops mid-line leaves the indexed prefix untouched.
          break
        } else if line.body_skipped {
          new_starts.push(line.start)
          new_firsts.push(total)
        } else if line.oversized {
          return Err(
            "transcript line " +
            reader.line_no.to_string() +
            " exceeds " +
            REPLAY_MAX_LINE_BYTES.to_string() +
            " bytes; replay is bounded per line",
          )
        } else if replay_prefix_zero_block(line.text) {
          new_starts.push(line.start)
          new_firsts.push(total)
        } else {
          let parsed : Json = @json.parse(line.text) catch {
            error =>
              if !line.terminated {
                break
              } else {
                return Err(
                  "malformed transcript line " +
                  reader.line_no.to_string() +
                  ": " +
                  error.to_string(),
                )
              }
          }
          match replay_block_count(parsed) {
            Ok(count) => {
              new_starts.push(line.start)
              new_firsts.push(total)
              total += count
            }
            Err(reason) =>
              if !line.terminated {
                break
              } else {
                return Err(
                  "malformed transcript line " +
                  reader.line_no.to_string() +
                  ": " +
                  reason,
                )
              }
          }
        }
    }
  }
  for start in new_starts {
    cached.starts.push(start)
  }
  for first in new_firsts {
    cached.firsts.push(first)
  }
  cached.total = total
  cached.size = reader.size
  cached.revision = revision
  cached.anchor = native_replay_tail_anchor(path, reader.size)
  cached.ended_with_newline = native_replay_ends_with_newline(path, reader.size)
  cached.incremental = true
  Ok(cached)
}

///|
/// Bounded per-session index cache. Entries are keyed by session id and
/// invalidated by the file revision (size + mtime); the oldest entry is evicted
/// when the cache grows past `REPLAY_CACHE_LIMIT`, so a long-lived native host
/// cannot accumulate one line table per resumed session.
pub struct NativeReplayCache {
  priv entries : Map[String, NativeReplayIndex]
  priv order : Array[String]
}

///|
fn NativeReplayCache::new() -> NativeReplayCache {
  { entries: Map([]), order: [], }
}

///|
fn NativeReplayCache::put(
  self : NativeReplayCache,
  index : NativeReplayIndex,
) -> Unit {
  let id = index.session_id
  let known = self.entries.contains(id)
  self.entries[id] = index
  if !known {
    self.order.push(id)
  }
  while self.order.length() > REPLAY_CACHE_LIMIT {
    let evicted = self.order.remove(0)
    self.entries.remove(evicted)
  }
}

///|
async fn native_replay_index_for(
  cache : NativeReplayCache,
  session_id : String,
  path : String,
) -> Result[NativeReplayIndex, String] {
  let revision = native_replay_revision(path)
  match cache.entries.get(session_id) {
    Some(cached) =>
      if cached.revision == revision && cached.path == path {
        // `incremental` is the storage slice's own diagnostic; reading it here
        // keeps it part of the cached table rather than a test-only artifact.
        ignore(cached.incremental)
        return Ok(cached)
      } else {
        match native_replay_extend_index(cached, path, revision) {
          Ok(extended) => {
            cache.put(extended)
            return Ok(extended)
          }
          Err(_) => ()
        }
      }
    None => ()
  }
  let built = match native_replay_build_index(session_id, path, revision) {
    Ok(built) => built
    Err(reason) => return Err(reason)
  }
  cache.put(built)
  Ok(built)
}

///|
/// The line table index holding `block` (the largest line whose first projected
/// block is at or before it).
fn native_replay_line_for_block(
  index : NativeReplayIndex,
  block : Int32,
) -> Int32 {
  let mut low = 0
  let mut high = index.firsts.length() - 1
  let mut found = 0
  while low <= high {
    let middle = (low + high) / 2
    if index.firsts[middle] <= block {
      found = middle
      low = middle + 1
    } else {
      high = middle - 1
    }
  }
  found
}

///|
priv enum NativeReplayMode {
  /// Full item bodies, bounded by `REPLAY_INLINE_BYTES` with range refs.
  Inline
  /// Metadata only (index): kinds, ids, status, payload lengths.
  Light
  /// Unbounded bodies for `transcript_source`; never framed directly.
  Raw
}

///|
priv struct NativeReplayProjector {
  mode : NativeReplayMode
  first : Int32
  limit : Int32
  max_bytes : Int32
  items : Array[Json]
  fields : Array[Map[String, Json]]
  slots : Map[String, Int32]
  pending : Map[String, Bool]
  mut block : Int32
  mut bytes : Int32
  mut full : Bool
}

///|
fn NativeReplayProjector::new(
  first : Int32,
  limit : Int32,
  max_bytes : Int32,
  mode : NativeReplayMode,
  start_block : Int32,
) -> NativeReplayProjector {
  {
    mode,
    first,
    limit,
    max_bytes,
    items: [],
    fields: [],
    slots: Map([]),
    pending: Map([]),
    block: start_block,
    bytes: 0,
    full: false,
  }
}

///|
fn replay_preview(text : String) -> String {
  if text.length() <= REPLAY_PREVIEW_CHARS {
    return text
  }
  // Count Unicode scalar values, not UTF-16 code units: a preview must never
  // split a surrogate pair while bounding the item shape.
  let builder = StringBuilder()
  let mut chars = 0
  for ch in text {
    if chars >= REPLAY_PREVIEW_CHARS {
      break
    }
    builder.write_char(ch)
    chars += 1
  }
  builder.to_string()
}

///|
fn replay_ref_json(block : Int32, field : String, length : Int32) -> Json {
  Json::object(
    Map::from_array([
      ("index", replay_int_json(block)),
      // Self-describing: the client passes this back to `transcript_source`.
      ("field", Json::string(field)),
      ("offset", replay_int_json(0)),
      ("length", replay_int_json(length)),
    ]),
  )
}

///|
/// Store one text/result payload according to the projector mode. Inline mode
/// keeps bodies up to `REPLAY_INLINE_BYTES`; beyond that the item carries a
/// bounded preview plus `textRef`/`resultRef`, which `transcript_source`
/// resolves into `REPLAY_SOURCE_MAX_BYTES` range chunks.
fn NativeReplayProjector::set_payload(
  self : NativeReplayProjector,
  fields : Map[String, Json],
  field : String,
  ref_field : String,
  value : String,
  block : Int32,
) -> Unit {
  let bytes = @utf8.encode(value)
  match self.mode {
    Raw => fields[field] = Json::string(value)
    Light => ()
    Inline =>
      if bytes.length() <= REPLAY_INLINE_BYTES {
        fields[field] = Json::string(value)
      } else {
        fields[field] = Json::string(replay_preview(value))
        fields[ref_field] = replay_ref_json(block, field, bytes.length())
      }
  }
}

///|
fn NativeReplayProjector::set_args(
  self : NativeReplayProjector,
  fields : Map[String, Json],
  args : Json,
  block : Int32,
) -> Unit {
  match self.mode {
    Raw => fields["args"] = args
    Light => ()
    Inline => {
      let size = @utf8.encode(args.stringify()).length()
      if size <= REPLAY_INLINE_BYTES {
        fields["args"] = args
      } else {
        fields["args"] = Json::null()
        fields["argsRef"] = replay_ref_json(block, "args", size)
      }
    }
  }
}

///|
/// Account one item against the page budget. Returns false when the item must
/// be dropped because the page is already full; the first item is always kept
/// (each item's inline payload is itself bounded).
fn NativeReplayProjector::accept(
  self : NativeReplayProjector,
  fields : Map[String, Json],
) -> Bool {
  let item = Json::object(fields)
  // Raw is an internal single-item payload lookup, never a wire frame. Sizing
  // it would serialize the whole giant body again for every source chunk.
  let size = match self.mode {
    Raw => 0
    _ => @utf8.encode(item.stringify()).length()
  }
  if self.items.length() > 0 &&
    (self.items.length() >= self.limit || self.bytes + size > self.max_bytes) {
    self.full = true
    return false
  }
  self.items.push(item)
  self.fields.push(fields)
  self.bytes += size
  if self.items.length() >= self.limit || self.bytes >= self.max_bytes {
    self.full = true
  }
  true
}

///|
fn NativeReplayProjector::add_text(
  self : NativeReplayProjector,
  kind : String,
  turn_id : String,
  text : String,
) -> Unit {
  let block = self.block
  self.block += 1
  if self.full || block < self.first || block >= self.first + self.limit {
    return
  }
  let fields : Map[String, Json] = Map::from_array([
    ("index", replay_int_json(block)),
    ("kind", Json::string(kind)),
    ("turnId", Json::string(turn_id)),
  ])
  match self.mode {
    Light => fields["textBytes"] = replay_int_json(@utf8.encode(text).length())
    Inline => {
      self.set_payload(fields, "text", "textRef", text, block)
      // Only streaming-capable kinds carry the flag; user items never do.
      if kind != "user" {
        fields["streaming"] = Json::boolean(false)
      }
    }
    Raw => {
      fields["text"] = Json::string(text)
      if kind != "user" {
        fields["streaming"] = Json::boolean(false)
      }
    }
  }
  ignore(self.accept(fields))
}

///|
fn NativeReplayProjector::add_tool(
  self : NativeReplayProjector,
  turn_id : String,
  call_id : String,
  name : String,
  args : Json,
) -> Unit {
  let block = self.block
  self.block += 1
  if self.full || block < self.first || block >= self.first + self.limit {
    return
  }
  let fields : Map[String, Json] = Map::from_array([
    ("index", replay_int_json(block)),
    ("kind", Json::string("tool")),
    ("turnId", Json::string(turn_id)),
    ("callId", Json::string(call_id)),
    ("name", Json::string(name)),
    ("status", Json::string("running")),
  ])
  match self.mode {
    Light => {
      fields["argsBytes"] = replay_int_json(
        @utf8.encode(args.stringify()).length(),
      )
      fields["resultBytes"] = replay_int_json(0)
    }
    Inline => {
      self.set_args(fields, args, block)
      fields["result"] = Json::string("")
    }
    Raw => {
      fields["args"] = args
      fields["result"] = Json::string("")
    }
  }
  if self.accept(fields) {
    let slot = self.items.length() - 1
    self.slots[call_id] = slot
    self.pending[call_id] = true
  }
}

///|
/// Patch a tool item with its ToolMessage. The result lives on a later line, so
/// this is the cross-page association point: a page keeps scanning forward
/// (bounded by the lookahead budget) until every tool item it emitted has been
/// resolved or the journal ends.
fn NativeReplayProjector::patch_tool(
  self : NativeReplayProjector,
  call_id : String,
  is_error : Bool,
  result : String,
) -> Unit {
  match self.slots.get(call_id) {
    Some(slot) => {
      let fields = self.fields[slot]
      fields["status"] = Json::string(if is_error { "error" } else { "done" })
      match self.mode {
        Light =>
          fields["resultBytes"] = replay_int_json(@utf8.encode(result).length())
        Inline => {
          let block = match fields.get("index") {
            Some(value) => replay_field_int(value)
            None => 0
          }
          self.set_payload(fields, "result", "resultRef", result, block)
        }
        Raw => fields["result"] = Json::string(result)
      }
      self.items[slot] = Json::object(fields)
      self.pending.remove(call_id)
      // The result can push a kept item over the page budget; the final size
      // pass in `native_replay_page` trims trailing items, so re-account here
      // only for the "still not full" fast path.
      if !self.full && self.items.length() < self.limit {
        self.bytes = self.recount()
        if self.bytes >= self.max_bytes {
          self.full = true
        }
      }
    }
    None => ()
  }
}

///|
fn replay_field_int(value : Json) -> Int32 {
  match value {
    Json::Number(number, ..) => number.to_int()
    _ => 0
  }
}

///|
fn NativeReplayProjector::recount(self : NativeReplayProjector) -> Int32 {
  let mut bytes = 0
  for item in self.items {
    bytes += @utf8.encode(item.stringify()).length()
  }
  bytes
}

///|
fn NativeReplayProjector::project(
  self : NativeReplayProjector,
  message : NativeReplayMessage,
  turn_id : String,
) -> Unit {
  if message.role == "tool" {
    self.patch_tool(message.call_id, message.is_error, message.text)
    return
  }
  for block in message.blocks {
    match block {
      NativeReplayBlock::Text(kind~, text~) =>
        self.add_text(kind, turn_id, text)
      NativeReplayBlock::Tool(call_id~, name~, args~) =>
        self.add_tool(turn_id, call_id, name, args)
    }
  }
}

///|
priv struct NativeReplayPageResult {
  items : Array[Json]
  first : Int32
  total : Int32
  next : Int32?
}

///|
/// Build one page by seeking to the line that holds absolute block `first` and
/// streaming forward. `limit`/`max_bytes` bound the page; lookahead keeps
/// scanning (bounded) so a tool call at the page edge still carries its result.
async fn native_replay_page(
  index : NativeReplayIndex,
  first : Int32,
  limit : Int32,
  max_bytes : Int32,
  mode : NativeReplayMode,
) -> Result[NativeReplayPageResult, String] {
  if first < 0 || first >= index.total {
    return Ok({ items: [], first, total: index.total, next: None, })
  }
  let start_line = native_replay_line_for_block(index, first)
  let reader = NativeReplayReader::open(
    index.path,
    chunk_bytes=REPLAY_CHUNK_BYTES,
  ) catch {
    error => return Err("cannot open transcript: " + error.to_string())
  }
  defer reader.file.close()
  reader.seek(index.starts[start_line])
  let projector = NativeReplayProjector::new(
    first,
    limit,
    max_bytes,
    mode,
    index.firsts[start_line],
  )
  let mut line = start_line
  while line < index.starts.length() {
    let next = match reader.next_line() {
      Some(line) => line
      None => break
    }
    if next.blank {
      continue
    }
    if next.oversized {
      if !next.terminated {
        // A torn tail (crash mid-append) is ignored, exactly as the index pass
        // ignores it: leftover page items stay as projected, and a pending tool
        // call keeps its truthful `running` state.
        break
      }
      return Err(
        "transcript line " +
        reader.line_no.to_string() +
        " exceeds " +
        REPLAY_MAX_LINE_BYTES.to_string() +
        " bytes; replay is bounded per line",
      )
    }
    let parsed : Json = @json.parse(next.text) catch {
      error =>
        if !next.terminated {
          break
        } else {
          return Err(
            "malformed transcript line " +
            reader.line_no.to_string() +
            ": " +
            error.to_string(),
          )
        }
    }
    let message = match replay_parse_message(parsed) {
      Ok(message) => message
      Err(reason) =>
        if !next.terminated {
          break
        } else {
          return Err(
            "malformed transcript line " +
            reader.line_no.to_string() +
            ": " +
            reason,
          )
        }
    }
    projector.project(message, "r-" + (line - 1).to_string())
    line += 1
    // Once the page is full only tool-result settlement keeps the scan going.
    // There is no line/byte lookahead cap: a persisted ToolMessage is the only
    // way to know a page tool finished, and reporting `running` for one that
    // already has a result later in the journal would be a fabricated state.
    // Such a scan settles immediately in the normal case (the result is the
    // next line) and, in the pathological case, is bounded by the journal end
    // with constant memory: lines are parsed one at a time and dropped.
    if projector.full && projector.pending.is_empty() {
      break
    }
  }
  // Final size pass: a late tool result can grow an already accepted item, so
  // trailing items are trimmed rather than letting the frame exceed budget.
  let kept : Array[Json] = []
  let mut bytes = 0
  for item in projector.items {
    // Inline/Light pages must obey the serialized frame budget. Raw lookup is
    // consumed locally by transcript_source, whose returned byte range is
    // independently capped; measuring this whole body has no framing purpose.
    let size = match mode {
      Raw => 0
      _ => @utf8.encode(item.stringify()).length()
    }
    if kept.length() > 0 && bytes + size > max_bytes {
      break
    }
    kept.push(item)
    bytes += size
  }
  let end = first + kept.length()
  let next = if end < index.total { Some(end) } else { None }
  Ok({ items: kept, first, total: index.total, next, })
}

///|
fn native_replay_mode_light() -> NativeReplayMode {
  NativeReplayMode::Light
}

///|
/// Index response: the session's revision, absolute projected-block total,
/// context state, and a bounded light window of block metadata (defaults to the
/// tail window so resume starts near the end of the journal). Bodies are never
/// included.
async fn native_replay_index_json(
  cache : NativeReplayCache,
  session_id : String,
  path : String,
  first : Int32,
  limit : Int32,
) -> Json {
  let index = match native_replay_index_for(cache, session_id, path) {
    Ok(index) => index
    Err(reason) => return replay_error(reason)
  }
  let window = if limit <= 0 { REPLAY_INDEX_WINDOW } else { limit }
  let window = if window > REPLAY_PAGE_MAX_LIMIT {
    REPLAY_PAGE_MAX_LIMIT
  } else {
    window
  }
  let start = if first >= 0 {
    first
  } else if index.total > window {
    index.total - window
  } else {
    0
  }
  let start = if start > index.total { index.total } else { start }
  let page = match
    native_replay_page(
      index,
      start,
      window,
      REPLAY_PAGE_DEFAULT_BYTES,
      native_replay_mode_light(),
    ) {
    Ok(page) => page
    Err(reason) => return replay_error(reason)
  }
  Json::object(
    Map::from_array([
      ("session_id", Json::string(session_id)),
      ("revision", Json::string(index.revision)),
      ("total", replay_int_json(index.total)),
      // Window metadata: the absolute block index of `items[0]` (or `total`
      // for an empty window). Consumers derive the tail window without a
      // second request; `transcript_page` remains the paging surface.
      ("first", replay_int_json(page.first)),
      ("context", index.context),
      ("items", Json::array(page.items)),
    ]),
  )
}

///|
/// Page response: absolute block indexes plus the existing transcript item
/// schema. A requested revision that no longer matches the journal is reported
/// as stale instead of silently replaying a different history.
async fn native_replay_page_json(
  cache : NativeReplayCache,
  session_id : String,
  path : String,
  revision : String,
  first : Int32,
  limit : Int32,
  max_bytes : Int32,
) -> Json {
  let index = match native_replay_index_for(cache, session_id, path) {
    Ok(index) => index
    Err(reason) => return replay_error(reason)
  }
  if revision != "" && revision != index.revision {
    return Json::object(
      Map::from_array([
        ("error", Json::string("stale transcript revision")),
        ("session_id", Json::string(session_id)),
        ("revision", Json::string(index.revision)),
      ]),
    )
  }
  let limit = if limit <= 0 {
    REPLAY_PAGE_DEFAULT_LIMIT
  } else if limit > REPLAY_PAGE_MAX_LIMIT {
    REPLAY_PAGE_MAX_LIMIT
  } else {
    limit
  }
  let max_bytes = if max_bytes <= 0 {
    REPLAY_PAGE_DEFAULT_BYTES
  } else if max_bytes > REPLAY_PAGE_MAX_BYTES {
    REPLAY_PAGE_MAX_BYTES
  } else {
    max_bytes
  }
  let page = match
    native_replay_page(
      index,
      if first < 0 {
        0
      } else {
        first
      },
      limit,
      max_bytes,
      NativeReplayMode::Inline,
    ) {
    Ok(page) => page
    Err(reason) => return replay_error(reason)
  }
  Json::object(
    Map::from_array([
      ("session_id", Json::string(session_id)),
      ("revision", Json::string(index.revision)),
      ("first", replay_int_json(page.first)),
      ("total", replay_int_json(page.total)),
      ("items", Json::array(page.items)),
      ("next", replay_optional_int_json(page.next)),
    ]),
  )
}

///|
/// Resolve one block's full payload (text for text blocks, result for tool
/// blocks) through the same projection, without inline caps.
async fn native_replay_payload(
  index : NativeReplayIndex,
  block : Int32,
  field : String,
) -> Result[String, String] {
  let page = match
    native_replay_page(
      index,
      block,
      1,
      REPLAY_PAGE_MAX_BYTES,
      NativeReplayMode::Raw,
    ) {
    Ok(page) => page
    Err(reason) => return Err(reason)
  }
  if page.items.length() == 0 {
    return Err("transcript block index out of range")
  }
  let item = page.items[0]
  let fields = match item {
    Json::Object(fields) => fields
    _ => return Err("transcript block is not an object")
  }
  let index_value = match fields.get("index") {
    Some(Json::Number(value, ..)) => value.to_int()
    _ => -1
  }
  if index_value != block {
    return Err("transcript block index could not be located")
  }
  let kind = match fields.get("kind") {
    Some(Json::String(kind)) => kind
    _ => ""
  }
  let field = if field == "" {
    if kind == "tool" {
      "result"
    } else {
      "text"
    }
  } else {
    field
  }
  match field {
    "args" =>
      match fields.get("args") {
        Some(args) => Ok(args.stringify())
        None => Err("transcript block has no args payload")
      }
    "result" =>
      if kind != "tool" {
        Err("transcript block has no result payload")
      } else {
        match fields.get("status") {
          Some(Json::String("running")) =>
            return Err("transcript tool block has no result yet")
          _ => ()
        }
        match fields.get("result") {
          Some(Json::String(result)) => Ok(result)
          _ => Err("transcript tool block has no result payload")
        }
      }
    "text" =>
      if kind == "tool" {
        Err("transcript tool block has no text payload")
      } else {
        match fields.get("text") {
          Some(Json::String(text)) => Ok(text)
          _ => Err("transcript block has no text payload")
        }
      }
    _ => Err("unknown transcript source field: " + field)
  }
}

///|
fn replay_utf8_lead(byte : Byte) -> Bool {
  (byte.to_int() & 0xC0) != 0x80
}

///|
/// Source response: one bounded byte range of a block's decoded payload. A
/// ref-bearing page item is followed by these chunks, never by a frame that
/// carries the whole body.
async fn native_replay_source_json(
  cache : NativeReplayCache,
  session_id : String,
  path : String,
  revision : String,
  block : Int32,
  field : String,
  offset : Int32,
  length : Int32,
) -> Json {
  let index = match native_replay_index_for(cache, session_id, path) {
    Ok(index) => index
    Err(reason) => return replay_error(reason)
  }
  if revision != "" && revision != index.revision {
    return Json::object(
      Map::from_array([
        ("error", Json::string("stale transcript revision")),
        ("session_id", Json::string(session_id)),
        ("revision", Json::string(index.revision)),
      ]),
    )
  }
  if block < 0 || block >= index.total {
    return replay_error("transcript block index out of range")
  }
  let payload = match native_replay_payload(index, block, field) {
    Ok(payload) => payload
    Err(reason) => return replay_error(reason)
  }
  let bytes = @utf8.encode(payload)
  let total_bytes = bytes.length()
  let mut start = if offset < 0 { 0 } else { offset }
  if start > total_bytes {
    start = total_bytes
  }
  // Land on a UTF-8 lead byte: a client that splits on arbitrary byte offsets
  // still receives decodable chunks at the cost of one skipped partial char.
  while start < total_bytes && !replay_utf8_lead(bytes.unsafe_get(start)) {
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
  if end > total_bytes {
    end = total_bytes
  }
  while end < total_bytes && !replay_utf8_lead(bytes.unsafe_get(end)) {
    end += 1
  }
  let data = @utf8.decode(bytes[start:end]) catch {
    _ => return replay_error("transcript source range is not valid UTF-8")
  }
  Json::object(
    Map::from_array([
      ("session_id", Json::string(session_id)),
      ("revision", Json::string(index.revision)),
      ("index", replay_int_json(block)),
      ("field", Json::string(if field == "" { "auto" } else { field })),
      ("offset", replay_int_json(start)),
      ("length", replay_int_json(end - start)),
      ("total_bytes", replay_int_json(total_bytes)),
      (
        "next",
        if end < total_bytes {
          replay_int_json(end)
        } else {
          Json::null()
        },
      ),
      ("data", Json::string(data)),
    ]),
  )
}

///|
/// Bounded display title for the native session list: the streaming summary's
/// title, never a full `load`.
async fn native_replay_title(
  session_id : String,
  path : String,
) -> Result[String, String] {
  let summary = match native_replay_summary(session_id, path) {
    Ok(summary) => summary
    Err(reason) => return Err(reason)
  }
  // The byte accounting is the streaming contract's own diagnostic; reading it
  // here keeps the field part of the summary, not a test-only artifact.
  ignore(summary.scanned)
  Ok(summary.title)
}

///|
/// Streaming session summary: metadata line only, plus the first user line when
/// the journal predates the `posoco.title` metadata contract. Bounded by
/// `REPLAY_SUMMARY_SCAN_BYTES`/`REPLAY_SUMMARY_LINES`; later journal content is
/// never read. Mirrors `JsonlSessionStore::summary` + `display_title`.
priv struct NativeReplaySummary {
  title : String
  /// Bytes read from the journal while resolving the title; the streaming
  /// reader's accounting, exposed so the bound is testable.
  scanned : Int64
}

///|
fn replay_collapse_whitespace(text : String) -> String {
  let builder = StringBuilder()
  let mut pending_space = false
  let mut written = 0
  for ch in text {
    let code = ch.to_int()
    if code == 0x20 || code == 0x09 || code == 0x0a || code == 0x0d {
      pending_space = true
    } else {
      if pending_space && written > 0 {
        builder.write_char(' ')
        written += 1
      }
      pending_space = false
      builder.write_char(ch)
      written += 1
    }
  }
  builder.to_string()
}

///|
fn replay_normalize_title(text : String) -> String? {
  let collapsed = replay_collapse_whitespace(text)
  if collapsed.is_empty() {
    None
  } else {
    Some(@devkit.truncate_chars(collapsed, 50))
  }
}

///|
fn replay_legacy_title(text : String) -> String? {
  replay_normalize_title(text)
}

///|
async fn native_replay_summary(
  session_id : String,
  path : String,
) -> Result[NativeReplaySummary, String] {
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return Ok({ title: session_id, scanned: 0L, })
  }
  let reader = NativeReplayReader::open(
    path,
    chunk_bytes=REPLAY_SUMMARY_CHUNK_BYTES,
  ) catch {
    error => return Err("cannot read session summary: " + error.to_string())
  }
  defer reader.file.close()
  let mut metadata : Map[String, Json] = Map([])
  let mut found_metadata = false
  while !found_metadata {
    match reader.next_line() {
      None => return Ok({ title: session_id, scanned: reader.bytes_read, })
      Some(line) =>
        if line.blank {
          continue
        } else if line.oversized && line.terminated {
          // Explicit, not a silent id-shaped title: an unreadable *complete*
          // metadata line is corruption the session list must surface.
          return Err(
            "session summary metadata line exceeds " +
            REPLAY_MAX_LINE_BYTES.to_string() +
            " bytes",
          )
        } else if line.oversized {
          // Torn tail with no complete line to recover to: the partial line is
          // ignored, so this is the empty session an untouched journal is.
          return Ok({ title: session_id, scanned: reader.bytes_read, })
        } else {
          let parsed : Json = @json.parse(line.text) catch {
            error =>
              if !line.terminated {
                return Ok({ title: session_id, scanned: reader.bytes_read, })
              } else {
                return Err(
                  "malformed session summary metadata line: " +
                  error.to_string(),
                )
              }
          }
          metadata = match parsed {
            Json::Object(fields) => fields
            _ => return Err("session summary metadata line is not an object")
          }
          found_metadata = true
        }
    }
  }
  let name = match metadata.get("name") {
    Some(Json::String(name)) if !name.is_empty() => Some(name)
    _ => None
  }
  let mut title = match metadata.get("posoco.title") {
    Some(Json::String(value)) => replay_normalize_title(value)
    _ => None
  }
  if title is None {
    let mut scanned : Int64 = 0L
    let mut lines = 0
    while scanned <= REPLAY_SUMMARY_SCAN_BYTES &&
          reader.bytes_read <=
          REPLAY_SUMMARY_SCAN_BYTES + REPLAY_SUMMARY_CHUNK_BYTES.to_int64() &&
          lines < REPLAY_SUMMARY_LINES {
      let line = match reader.next_line() {
        Some(line) => line
        None => break
      }
      if line.blank {
        continue
      }
      if line.oversized && line.terminated {
        return Err(
          "session summary line exceeds " +
          REPLAY_MAX_LINE_BYTES.to_string() +
          " bytes",
        )
      }
      if line.oversized {
        break
      }
      scanned += line.length.to_int64()
      lines += 1
      let parsed : Json = @json.parse(line.text) catch {
        error =>
          if !line.terminated {
            break
          } else {
            return Err(
              "malformed session summary line " +
              reader.line_no.to_string() +
              ": " +
              error.to_string(),
            )
          }
      }
      match replay_parse_message(parsed) {
        Ok(message) =>
          if message.role == "user" {
            // Legacy first-user title joins its text blocks without
            // separators, exactly like the fs-session summary fallback.
            title = replay_legacy_title(message.text)
            break
          }
        Err(reason) =>
          if !line.terminated {
            break
          } else {
            return Err(
              "malformed session summary line " +
              reader.line_no.to_string() +
              ": " +
              reason,
            )
          }
      }
    }
  }
  let display = match (name, title) {
    (Some(name), _) => name
    (None, Some(title)) => title
    (None, None) => session_id
  }
  Ok({ title: display, scanned: reader.bytes_read, })
}
