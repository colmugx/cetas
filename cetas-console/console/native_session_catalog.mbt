///|
/// Lightweight native `/sessions` catalog.
///
/// The shared catalog lists sessions through the runtime's compiled-in store
/// (`list_ids` + `entry`), and `entry` goes through `summary`, which loads the
/// whole journal. The native host needs the same discoverability without an
/// Agent or a workspace runtime: this file walks the persisted bucket layout
/// directly, stats `.jsonl` files, and reads only the bounded metadata prefix
/// needed for a row's title and recorded project directory.
///
/// The response is a page, not a whole history:
///
/// ```
/// {
///   "scope": "current" | "all",
///   "cwd": active project directory,
///   "items": [{ id, bucket, title, cwd, folder, sizeBytes, modifiedAt,
///               current, resumable, reason? }],
///   "next": anchor | null,
///   "total": matching row count (scan-time upper bound),
///   "warnings": [{ kind, bucket, id, message }]?   // only when non-empty
/// }
/// ```
///
/// A row is keyed by `(bucket, id)`, never by `id` alone: the same clock-minted
/// id may exist in two projects' buckets. Pages are ordered by modification
/// time descending with the identity as the stable tie-break, so identical
/// file timestamps still order deterministically.
///
/// No arbitrary path is derived from disk or wire data: bucket directory names
/// are re-checked against the fs-session bucket layout and id stems are
/// re-validated by `@fs_session.validate_session_id` before they are joined to
/// the root.

///|
/// Hard row cap: one response never carries more than this many rows.
const NATIVE_SESSION_CATALOG_MAX_ROWS : Int32 = 200

///|
/// Hard serialized cap for one response. Rows are measured as they are built
/// and the page stops early instead of constructing an unbounded wire value.
const NATIVE_SESSION_CATALOG_MAX_BYTES : Int32 = 1024 * 1024

///|
/// Space reserved for the envelope (scope/cwd/next/total/warnings) so the
/// measured row bytes can stay overwhelmingly under the hard cap.
const NATIVE_SESSION_CATALOG_WIRE_RESERVE : Int32 = 128 * 1024

///|
/// Warnings are diagnostic, not a transcript of the whole disk: an unreadable
/// session farm yields a bounded warning list plus one truncation notice.
const NATIVE_SESSION_CATALOG_MAX_WARNINGS : Int32 = 16

///|
const NATIVE_SESSION_CATALOG_MAX_ID_CHARS : Int32 = 256

///|
const NATIVE_SESSION_CATALOG_MAX_BUCKET_CHARS : Int32 = 256

///|
/// Recorded project directories are real paths; anything larger than this is
/// treated as unrecorded rather than copied into the wire value.
const NATIVE_SESSION_CATALOG_MAX_CWD_CHARS : Int32 = 4096

///|
/// The automatic title is already capped at 50 chars; an explicit rename can
/// be arbitrarily long, so the catalog caps it for the session list.
const NATIVE_SESSION_CATALOG_MAX_TITLE_CHARS : Int32 = 200

///|
const NATIVE_SESSION_CATALOG_MAX_MESSAGE_CHARS : Int32 = 200

///|
const NATIVE_SESSION_CATALOG_MAX_ERROR_CHARS : Int32 = 512

///|
/// One statted `.jsonl` file. Metadata is deliberately absent here: it is read
/// only for rows that survive sorting, cursor and limit selection.
priv struct NativeSessionCatalogCandidate {
  bucket : String
  id : String
  path : String
  size_bytes : Int64
  modified_ms : Int64
}

///|
/// Bounded warning sink. Each warning is small and the list is capped; the one
/// synthetic "warnings-truncated" entry keeps the omission visible.
priv struct NativeSessionCatalogWarnings {
  items : Array[Json]
  mut dropped : Int32
}

///|
fn NativeSessionCatalogWarnings::new() -> NativeSessionCatalogWarnings {
  { items: [], dropped: 0, }
}

///|
fn NativeSessionCatalogWarnings::add(
  self : NativeSessionCatalogWarnings,
  kind : String,
  bucket : String,
  id : String,
  message : String,
) -> Unit {
  if self.items.length() >= NATIVE_SESSION_CATALOG_MAX_WARNINGS {
    self.dropped += 1
    return
  }
  self.items.push(
    Json::object(
      Map::from_array([
        ("kind", Json::string(kind)),
        (
          "bucket",
          if bucket.is_empty() {
            Json::null()
          } else {
            Json::string(bucket)
          },
        ),
        ("id", if id.is_empty() { Json::null() } else { Json::string(id) }),
        (
          "message",
          Json::string(
            native_session_catalog_clip(
              message,
              NATIVE_SESSION_CATALOG_MAX_MESSAGE_CHARS,
            ),
          ),
        ),
      ]),
    ),
  )
}

///|
fn NativeSessionCatalogWarnings::to_json(
  self : NativeSessionCatalogWarnings,
) -> Array[Json] {
  let items = self.items.copy()
  if self.dropped > 0 {
    items.push(
      Json::object(
        Map::from_array([
          ("kind", Json::string("warnings-truncated")),
          ("bucket", Json::null()),
          ("id", Json::null()),
          (
            "message",
            Json::string(self.dropped.to_string() + " more catalog warnings"),
          ),
        ]),
      ),
    )
  }
  items
}

///|
fn native_session_catalog_clip(text : String, cap : Int32) -> String {
  @devkit.truncate_chars(text, cap)
}

///|
fn native_session_catalog_error(
  scope : String,
  cwd : String,
  message : String,
) -> Json {
  Json::object(
    Map::from_array([
      (
        "scope",
        if scope.is_empty() {
          Json::null()
        } else {
          Json::string(scope)
        },
      ),
      ("cwd", if cwd.is_empty() { Json::null() } else { Json::string(cwd) }),
      (
        "error",
        Json::string(
          native_session_catalog_clip(
            message,
            NATIVE_SESSION_CATALOG_MAX_ERROR_CHARS,
          ),
        ),
      ),
    ]),
  )
}

///|
/// Only the two native scopes exist. An empty scope is the picker's default
/// (`current`); `default` is accepted as an explicit spelling of the same
/// thing. Anything else is a caller bug and must not silently widen to `all`.
fn native_session_catalog_scope(scope : String) -> Result[String, String] {
  if scope.is_empty() || scope == "current" || scope == "default" {
    Ok("current")
  } else if scope == "all" {
    Ok("all")
  } else {
    Err(
      "unknown session catalog scope: " +
      native_session_catalog_clip(scope, 64) +
      " (expected \"current\" or \"all\")",
    )
  }
}

///|
/// Bucket names become path segments. The shared formula only emits
/// `session_<slug>_<hex>`; this guard checks the `session_` prefix plus a
/// path-safe charset, which rejects `.`/`..`, separators and hidden names
/// before the join. It does not re-derive the slug/hex shape itself.
fn native_session_catalog_bucket_safe(name : String) -> Bool {
  if name.length() == 0 ||
    name.length() > NATIVE_SESSION_CATALOG_MAX_BUCKET_CHARS {
    return false
  }
  if name == "." || name == ".." || !@fs_session.is_project_dir_name(name) {
    return false
  }
  for ch in name {
    let code = ch.to_int()
    let ascii_lower = code >= 0x61 && code <= 0x7a
    let ascii_upper = code >= 0x41 && code <= 0x5a
    let ascii_digit = code >= 0x30 && code <= 0x39
    if !ascii_lower &&
      !ascii_upper &&
      !ascii_digit &&
      code != 0x2e &&
      code != 0x5f &&
      code != 0x2d {
      return false
    }
  }
  true
}

///|
/// Session ids become filename stems; the store's own validator is the
/// authority, and the catalog only adds the wire-size bound.
fn native_session_catalog_id_safe(id : String) -> Bool {
  if id.length() == 0 || id.length() > NATIVE_SESSION_CATALOG_MAX_ID_CHARS {
    return false
  }
  @fs_session.validate_session_id(id) is Ok(_)
}

///|
/// Char-lexicographic order, not MoonBit's length-first String order: clock
/// ids and bucket names stay chronological/stable under this comparator.
fn native_session_catalog_compare_string(
  left : String,
  right : String,
) -> Int32 {
  let shared = if left.length() < right.length() {
    left.length()
  } else {
    right.length()
  }
  for index = 0; index < shared; index = index + 1 {
    let left_char = left[index]
    let right_char = right[index]
    if left_char != right_char {
      if left_char < right_char {
        return -1
      }
      return 1
    }
  }
  if left.length() == right.length() {
    0
  } else if left.length() < right.length() {
    -1
  } else {
    1
  }
}

///|
/// Newest first, then `(bucket, id)` ascending as the stable identity
/// tie-break. The same id in two buckets therefore has two deterministic rows.
fn native_session_catalog_compare(
  left : NativeSessionCatalogCandidate,
  right : NativeSessionCatalogCandidate,
) -> Int32 {
  if left.modified_ms != right.modified_ms {
    if left.modified_ms > right.modified_ms {
      return -1
    }
    return 1
  }
  let by_bucket = native_session_catalog_compare_string(
    left.bucket,
    right.bucket,
  )
  if by_bucket != 0 {
    return by_bucket
  }
  native_session_catalog_compare_string(left.id, right.id)
}

///|
/// Metadata the picker needs from a journal's bounded prefix: the display
/// title, the recorded project directory, and whether the legacy title scan
/// had to give up. A degraded scan costs the title only — the row stays
/// resumable because the metadata line and the recorded directory were read.
priv struct NativeSessionCatalogMeta {
  title : String?
  cwd : String?
  title_degraded : String?
}

///|
/// Classified outcome of one bounded metadata read. An I/O failure is never
/// reported as corruption: the picker shows the row with the stat it has and
/// names the real failure.
priv enum NativeSessionCatalogMetaRead {
  SessionMissing
  SessionMeta(NativeSessionCatalogMeta)
  SessionUnreadable(String)
  SessionCorrupt(String)
}

///|
/// One bounded streaming pass for a row's title and recorded project
/// directory: the journal is opened once and the metadata line is parsed once,
/// and the legacy first-user scan only runs when the metadata carries no
/// title. A torn tail is the empty/legacy case; a malformed *terminated*
/// metadata line is corruption; a read error is unreadable.
async fn native_session_catalog_meta(
  path : String,
) -> NativeSessionCatalogMetaRead {
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return SessionMissing
  }
  let reader = NativeReplayReader::open(
    path,
    chunk_bytes=REPLAY_SUMMARY_CHUNK_BYTES,
  ) catch {
    error => return SessionUnreadable(error.to_string())
  }
  defer reader.file.close()
  let mut metadata : Map[String, Json] = Map([])
  let mut have_metadata = false
  while !have_metadata {
    match reader.next_line() {
      None =>
        return SessionMeta({ title: None, cwd: None, title_degraded: None, })
      Some(line) =>
        if line.blank {
          continue
        } else if line.oversized && line.terminated {
          return SessionCorrupt(
            "session metadata line exceeds " +
            REPLAY_MAX_LINE_BYTES.to_string() +
            " bytes",
          )
        } else if line.oversized {
          // Torn tail: the partial line is ignored, exactly like the summary
          // fallback; there is no metadata to recover.
          return SessionMeta({ title: None, cwd: None, title_degraded: None, })
        } else {
          let parsed : Json = @json.parse(line.text) catch {
            error =>
              if !line.terminated {
                return SessionMeta({
                  title: None,
                  cwd: None,
                  title_degraded: None,
                })
              } else {
                return SessionCorrupt(
                  "malformed session metadata line: " + error.to_string(),
                )
              }
          }
          metadata = match parsed {
            Json::Object(fields) => fields
            _ => return SessionCorrupt("session metadata line is not an object")
          }
          have_metadata = true
        }
    }
  }
  let cwd = @fs_session.session_cwd_from_metadata(metadata)
  let name = match metadata.get("name") {
    Some(Json::String(name)) if !name.is_empty() => Some(name)
    _ => None
  }
  let title = match metadata.get("posoco.title") {
    Some(Json::String(value)) => replay_normalize_title(value)
    _ => None
  }
  if name is Some(_) || title is Some(_) {
    return SessionMeta({
      title: if name is Some(_) {
        name
      } else {
        title
      },
      cwd,
      title_degraded: None,
    })
  }
  // Legacy journal: scan the first user message for a title. Unlike the
  // replay summary, a malformed line here only degrades the title — the
  // metadata line and the recorded directory were already read successfully,
  // so the session itself is not corrupt.
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
      return SessionMeta({
        title: None,
        cwd,
        title_degraded: Some(
          "session line exceeds " + REPLAY_MAX_LINE_BYTES.to_string() + " bytes",
        ),
      })
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
          return SessionMeta({
            title: None,
            cwd,
            title_degraded: Some(
              "malformed session line " +
              reader.line_no.to_string() +
              ": " +
              error.to_string(),
            ),
          })
        }
    }
    match replay_parse_message(parsed) {
      Ok(message) =>
        if message.role == "user" {
          return SessionMeta({
            title: replay_legacy_title(message.text),
            cwd,
            title_degraded: None,
          })
        }
      Err(reason) =>
        if !line.terminated {
          break
        } else {
          return SessionMeta({
            title: None,
            cwd,
            title_degraded: Some(
              "malformed session line " +
              reader.line_no.to_string() +
              ": " +
              reason,
            ),
          })
        }
    }
  }
  SessionMeta({ title: None, cwd, title_degraded: None, })
}

///|
/// One page row, or `None` when the file disappeared between the directory
/// scan and the metadata read (the caller records the warning and skips the
/// stale candidate rather than rendering a ghost row).
async fn native_session_catalog_row_json(
  candidate : NativeSessionCatalogCandidate,
  active_bucket : String,
  active_id : String,
  warnings : NativeSessionCatalogWarnings,
) -> Json? {
  let mut title = candidate.id
  let mut cwd : String? = None
  let mut unreadable : String? = None
  let mut corrupt : String? = None
  let mut degraded : String? = None
  match native_session_catalog_meta(candidate.path) {
    SessionMissing => {
      warnings.add(
        "disappeared",
        candidate.bucket,
        candidate.id,
        "session file vanished while its metadata was being read",
      )
      return None
    }
    SessionUnreadable(detail) => unreadable = Some(detail)
    SessionCorrupt(detail) => corrupt = Some(detail)
    SessionMeta(meta) => {
      cwd = meta.cwd
      degraded = meta.title_degraded
      match meta.title {
        Some(found) => title = found
        None => ()
      }
    }
  }
  let mut title_truncated = false
  if title.length() > NATIVE_SESSION_CATALOG_MAX_TITLE_CHARS {
    title = native_session_catalog_clip(
      title,
      NATIVE_SESSION_CATALOG_MAX_TITLE_CHARS,
    )
    title_truncated = true
  }
  let cwd_too_long = match cwd {
    Some(path) => path.length() > NATIVE_SESSION_CATALOG_MAX_CWD_CHARS
    None => false
  }
  if cwd_too_long {
    cwd = None
  }
  let in_current_bucket = candidate.bucket == active_bucket
  let current = in_current_bucket && candidate.id == active_id
  let mut resumable = true
  let mut reason : String? = None
  match corrupt {
    Some(detail) => {
      // A journal whose metadata line itself cannot be parsed is still shown:
      // the id-shaped title makes it recognizable and the warning names the
      // corruption, instead of the row silently disappearing from the list.
      resumable = false
      reason = Some(
        native_session_catalog_clip(
          "corrupt session metadata: " + detail,
          NATIVE_SESSION_CATALOG_MAX_MESSAGE_CHARS,
        ),
      )
      warnings.add("corrupt", candidate.bucket, candidate.id, detail)
    }
    None =>
      match unreadable {
        Some(detail) => {
          // The stat-based row stays visible and the failure is named for
          // what it is; only a foreign row loses its resumability, because
          // its recorded project directory could not be read.
          warnings.add("unreadable", candidate.bucket, candidate.id, detail)
          if !in_current_bucket {
            resumable = false
            reason = Some(
              "session unreadable; cannot resume from another project",
            )
          }
        }
        None =>
          if !in_current_bucket && cwd is None {
            // The bucket hash cannot be reversed, so a foreign legacy journal has
            // no knowable project to switch to. Say so explicitly.
            resumable = false
            reason = Some(
              "no project folder recorded; cannot resume from another project",
            )
          }
      }
  }
  if degraded is Some(detail) {
    warnings.add(
      "title-degraded",
      candidate.bucket,
      candidate.id,
      "legacy title scan gave up: " + detail,
    )
  }
  if title_truncated {
    warnings.add(
      "title-truncated",
      candidate.bucket,
      candidate.id,
      "session title was truncated for the catalog wire",
    )
  }
  if cwd_too_long {
    warnings.add(
      "invalid-cwd",
      candidate.bucket,
      candidate.id,
      "recorded project folder exceeds the catalog limit",
    )
  }
  let fields = Map::from_array([
    ("id", Json::string(candidate.id)),
    ("bucket", Json::string(candidate.bucket)),
    ("title", Json::string(title)),
    (
      "cwd",
      match cwd {
        Some(path) => Json::string(path)
        None => Json::null()
      },
    ),
    ("folder", Json::string(@fs_session.bucket_slug(candidate.bucket))),
    ("sizeBytes", Json::number(candidate.size_bytes.to_double())),
    ("modifiedAt", Json::number(candidate.modified_ms.to_double())),
    ("current", Json::boolean(current)),
    ("resumable", Json::boolean(resumable)),
  ])
  match reason {
    Some(text) => fields["reason"] = Json::string(text)
    None => ()
  }
  Some(Json::object(fields))
}

///|
/// Stat every addressable `.jsonl` entry of one bucket. Non-session files are
/// ignored; `.jsonl` entries that cannot be a session id or a regular file are
/// reported as warnings rather than silently disappearing.
async fn native_session_catalog_scan_bucket(
  bucket_dir : String,
  bucket : String,
  warnings : NativeSessionCatalogWarnings,
) -> Result[Array[NativeSessionCatalogCandidate], String] {
  let names = @fs.readdir(bucket_dir, include_hidden=false) catch {
    error =>
      return Err(
        "cannot list sessions bucket " + bucket + ": " + error.to_string(),
      )
  }
  let entries : Array[NativeSessionCatalogCandidate] = []
  for name in names {
    if !name.has_suffix(".jsonl") {
      continue
    }
    let id = name.exact_view(start=0, end=name.length() - 6).to_owned()
    if !native_session_catalog_id_safe(id) {
      warnings.add(
        "invalid-session-id", bucket, id, "ignored .jsonl entry whose stem is not an addressable session id",
      )
      continue
    }
    let path = bucket_dir + "/" + name
    let kind = @fs.kind(path, follow_symlink=false) catch {
      _ => {
        warnings.add(
          "disappeared", bucket, id, "session file vanished while the catalog was scanning",
        )
        continue
      }
    }
    match kind {
      @fs.Regular => ()
      _ => {
        warnings.add(
          "not-a-file", bucket, id, "ignored .jsonl entry that is not a regular file",
        )
        continue
      }
    }
    let size_bytes = @fs.file_size(path) catch {
      _ => {
        warnings.add(
          "disappeared", bucket, id, "session file vanished while the catalog was statting it",
        )
        continue
      }
    }
    let mtime = @fs.mtime(path) catch {
      _ => {
        warnings.add(
          "disappeared", bucket, id, "session file vanished while the catalog was statting it",
        )
        continue
      }
    }
    entries.push({ bucket, id, path, size_bytes, modified_ms: mtime.msec(), })
  }
  Ok(entries)
}

///|
/// Walk the bucket directories under `project_sessions_root(home)`.
///
/// A missing root is an empty catalog (first run). A root that exists but is
/// not a directory, or cannot be listed, is an explicit error so "no sessions"
/// and "I/O failed" never look the same. Per-bucket failures degrade to
/// warnings in the `all` scope; in `current` the active bucket is the whole
/// answer, so its failure is explicit.
async fn native_session_catalog_scan(
  home : String,
  active_bucket : String,
  scope : String,
  warnings : NativeSessionCatalogWarnings,
) -> Result[Array[NativeSessionCatalogCandidate], String] {
  let root = @fs_session.project_sessions_root(home)
  let root_exists = @fs.exists(root) catch {
    error =>
      return Err(
        "cannot inspect sessions root " + root + ": " + error.to_string(),
      )
  }
  if !root_exists {
    return Ok([])
  }
  let root_kind = @fs.kind(root, follow_symlink=true) catch {
    error =>
      return Err(
        "cannot inspect sessions root " + root + ": " + error.to_string(),
      )
  }
  match root_kind {
    @fs.Directory => ()
    _ => return Err("sessions root is not a directory: " + root)
  }
  let names = @fs.readdir(root, include_hidden=false) catch {
    error =>
      return Err("cannot list sessions root " + root + ": " + error.to_string())
  }
  let candidates : Array[NativeSessionCatalogCandidate] = []
  for name in names {
    if scope == "current" && name != active_bucket {
      continue
    }
    if !native_session_catalog_bucket_safe(name) {
      // A merely different directory (`notes`, `.git`) is just not a bucket;
      // only names claiming the bucket prefix are worth a warning.
      if @fs_session.is_project_dir_name(name) {
        warnings.add(
          "invalid-bucket", name, "", "ignored session bucket with an unsafe name",
        )
      }
      continue
    }
    let dir = root + "/" + name
    let kind = @fs.kind(dir, follow_symlink=false) catch {
      _ => {
        warnings.add(
          "bucket-unreadable", name, "", "cannot inspect session bucket",
        )
        continue
      }
    }
    match kind {
      @fs.Directory => ()
      _ => {
        warnings.add(
          "invalid-bucket", name, "", "ignored session bucket entry that is not a directory",
        )
        continue
      }
    }
    match native_session_catalog_scan_bucket(dir, name, warnings) {
      Ok(entries) =>
        for entry in entries {
          candidates.push(entry)
        }
      Err(reason) =>
        if scope == "current" {
          return Err(reason)
        } else {
          warnings.add("bucket-unreadable", name, "", reason)
        }
    }
  }
  Ok(candidates)
}

///|
/// Keyset anchor: the sort identity of the last row a page emitted. The next
/// page resumes strictly after this tuple, so a journal appended while the
/// picker is open can move rows to the front without duplicating or skipping
/// anything the way a row offset would.
priv struct NativeSessionCatalogAnchor {
  modified_ms : Int64
  bucket : String
  id : String
}

///|
fn native_session_catalog_anchor_of(
  candidate : NativeSessionCatalogCandidate,
) -> NativeSessionCatalogAnchor {
  {
    modified_ms: candidate.modified_ms,
    bucket: candidate.bucket,
    id: candidate.id,
  }
}

///|
/// The anchor is an opaque string on the wire — a stringified JSON array —
/// so hosts round-trip it as one value. Only this module writes or reads it,
/// and the payload parts are re-validated on parse.
fn native_session_catalog_anchor_json(
  anchor : NativeSessionCatalogAnchor,
) -> Json {
  Json::string(
    Json::array([
      Json::number(anchor.modified_ms.to_double()),
      Json::string(anchor.bucket),
      Json::string(anchor.id),
    ]).stringify(),
  )
}

///|
fn native_session_catalog_anchor_parse(
  text : String,
) -> Result[NativeSessionCatalogAnchor, String] {
  let invalid = Err("invalid session catalog cursor")
  let parsed : Json = @json.parse(text) catch { _ => return invalid }
  match parsed {
    Json::Array(parts) =>
      if parts.length() != 3 {
        invalid
      } else {
        match (parts[0], parts[1], parts[2]) {
          (Json::Number(ms, ..), Json::String(bucket), Json::String(id)) =>
            if native_session_catalog_bucket_safe(bucket) &&
              native_session_catalog_id_safe(id) {
              Ok({ modified_ms: ms.to_int64(), bucket, id, })
            } else {
              invalid
            }
          _ => invalid
        }
      }
    _ => invalid
  }
}

///|
/// Reports whether `candidate` sorts strictly after `anchor` in page order
/// (newest first, then bucket and id ascending): exactly the rows a later
/// page may still emit.
fn native_session_catalog_after_anchor(
  candidate : NativeSessionCatalogCandidate,
  anchor : NativeSessionCatalogAnchor,
) -> Bool {
  if candidate.modified_ms != anchor.modified_ms {
    return candidate.modified_ms < anchor.modified_ms
  }
  let by_bucket = native_session_catalog_compare_string(
    candidate.bucket,
    anchor.bucket,
  )
  if by_bucket != 0 {
    return by_bucket > 0
  }
  native_session_catalog_compare_string(candidate.id, anchor.id) > 0
}

///|
/// Native-only session catalog page.
///
/// `scope` is `current`/`default`/empty (the active project's bucket) or `all`
/// (every project bucket on disk). `after` is the opaque anchor the previous
/// page returned in `next` (empty for page 0); `limit` is clamped to
/// `NATIVE_SESSION_CATALOG_MAX_ROWS`, with a non-positive value meaning the
/// full cap. Rows are ordered newest first and paged under both a row and a
/// serialized-byte budget. `total` is the scan-time candidate count; rows can
/// vanish between the scan and their read, so it is an upper bound.
///
/// The helper is package-private on purpose: the runtime/harness wiring is the
/// host's job, and this seam builds no Agent and no workspace.
async fn native_session_catalog_json(
  home : String,
  active_cwd : String,
  active_id : String,
  scope : String,
  after : String,
  limit : Int32,
) -> Json {
  let normalized = match native_session_catalog_scope(scope) {
    Ok(normalized) => normalized
    Err(reason) =>
      return native_session_catalog_error(scope, active_cwd, reason)
  }
  if active_cwd.length() > NATIVE_SESSION_CATALOG_MAX_CWD_CHARS {
    return native_session_catalog_error(
      normalized, "", "active project directory exceeds the catalog limit",
    )
  }
  let anchor : NativeSessionCatalogAnchor? = if after.is_empty() {
    None
  } else {
    match native_session_catalog_anchor_parse(after) {
      Ok(anchor) => Some(anchor)
      Err(reason) =>
        return native_session_catalog_error(normalized, active_cwd, reason)
    }
  }
  let active_bucket = @fs_session.project_dir_name(active_cwd)
  if !native_session_catalog_bucket_safe(active_bucket) {
    return native_session_catalog_error(
      normalized, active_cwd, "active project directory does not map to a safe session bucket",
    )
  }
  let warnings = NativeSessionCatalogWarnings::new()
  let candidates = match
    native_session_catalog_scan(home, active_bucket, normalized, warnings) {
    Ok(candidates) => candidates
    Err(reason) =>
      return native_session_catalog_error(normalized, active_cwd, reason)
  }
  candidates.sort_by(native_session_catalog_compare)
  let total = candidates.length()
  let requested = if limit <= 0 {
    NATIVE_SESSION_CATALOG_MAX_ROWS
  } else {
    limit
  }
  let capped = if requested > NATIVE_SESSION_CATALOG_MAX_ROWS {
    NATIVE_SESSION_CATALOG_MAX_ROWS
  } else {
    requested
  }
  let items : Array[Json] = []
  let mut index = 0
  let mut wire_bytes = NATIVE_SESSION_CATALOG_WIRE_RESERVE
  let mut last_emitted : NativeSessionCatalogAnchor? = None
  let mut last_examined : NativeSessionCatalogAnchor? = None
  while index < total && items.length() < capped {
    let candidate = candidates[index]
    match anchor {
      Some(anchor) =>
        if !native_session_catalog_after_anchor(candidate, anchor) {
          // At or before the anchor: a row an earlier page already served.
          index += 1
          continue
        }
      None => ()
    }
    last_examined = Some(native_session_catalog_anchor_of(candidate))
    match
      native_session_catalog_row_json(
        candidate, active_bucket, active_id, warnings,
      ) {
      None => {
        index += 1
        continue
      }
      Some(row) => {
        let row_bytes = @utf8.encode(row.stringify()).length()
        if items.length() > 0 &&
          wire_bytes + row_bytes + 1 > NATIVE_SESSION_CATALOG_MAX_BYTES {
          break
        }
        items.push(row)
        wire_bytes += row_bytes + 1
        last_emitted = Some(native_session_catalog_anchor_of(candidate))
        index += 1
      }
    }
  }
  let next : Json = if index >= total {
    Json::null()
  } else {
    match last_emitted {
      Some(anchor) => native_session_catalog_anchor_json(anchor)
      None =>
        // Every examined row vanished while being read. Anchor past them so
        // the next page cannot loop on permanently missing rows.
        match last_examined {
          Some(anchor) => native_session_catalog_anchor_json(anchor)
          None => Json::null()
        }
    }
  }
  let fields = Map::from_array([
    ("scope", Json::string(normalized)),
    ("cwd", Json::string(active_cwd)),
    ("items", Json::array(items)),
    ("next", next),
    ("total", Json::number(total.to_double())),
  ])
  let warning_items = warnings.to_json()
  if warning_items.length() > 0 {
    fields["warnings"] = Json::array(warning_items)
  }
  Json::object(fields)
}
