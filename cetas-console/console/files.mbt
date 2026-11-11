///|
/// Workspace file index powering `@` mentions — relative paths from the
/// active workspace root; directories carry a trailing `/` (cetas-js
/// semantics: inserting a directory continues completion, a file ends the
/// mention with a space). Hidden entries are skipped by `readdir`; known
/// junk build dirs are pruned by name so the walk stays bounded.
const FILE_INDEX_TTL_MS : Int64 = 30_000

///|
const FILE_INDEX_CAP : Int32 = 20_000

///|
const FILE_INDEX_MAX_DEPTH : Int32 = 32

///|
/// Ignore patterns for the `@`-mention file index, mirroring
/// `WorkspacePolicy::checked` so completion offers the same tree the
/// glob/read tools see (identical to the JS host's workspace_index.mbt).
fn workspace_mention_ignore_patterns() -> Array[String] {
  ["node_modules", ".git", ".hg", ".svn", "_build", "target"]
}

///|
fn file_entry_dir(entry : String) -> Bool {
  entry.has_suffix("/")
}

///|
/// The entry without its trailing directory marker.
fn file_entry_clean(entry : String) -> String {
  if file_entry_dir(entry) {
    entry[0:entry.length() - 1].to_owned()
  } else {
    entry
  }
}

///|
fn file_entry_basename(entry : String) -> String {
  let clean = file_entry_clean(entry)
  match clean.rev_find("/") {
    Some(i) => clean[i + 1:].to_owned()
    None => clean
  }
}

///|
/// Depth-first walk over the WorkspaceFs, the JS host's workspace_index_walk:
/// segment-wise ignore matching, non-following stat for the dir/file split,
/// per-directory sort for deterministic order, bounded by max entries and
/// depth. Unreadable or unstatable entries are skipped.
async fn workspace_index_walk(
  fs : &@workspace.WorkspaceFs,
  dir : String,
  rel_prefix : String,
  ignore_patterns : Array[String],
  max_entries : Int32,
  out : Array[String],
  depth : Int32,
) -> Unit noraise {
  if out.length() >= max_entries || depth > FILE_INDEX_MAX_DEPTH {
    return
  }
  let entries = fs.readdir(dir, include_hidden=true) catch { _ => return }
  let names = entries.copy()
  names.sort()
  for name in names {
    if out.length() >= max_entries {
      return
    }
    let rel = rel_prefix + name
    if @workspace.matches_ignore(rel, ignore_patterns) {
      continue
    }
    let child = if dir.has_suffix("/") { dir + name } else { dir + "/" + name }
    let kind = fs.kind(child, follow_symlink=false) catch { _ => continue }
    match kind {
      Dir => {
        out.push(rel + "/")
        workspace_index_walk(
          fs,
          child,
          rel + "/",
          ignore_patterns,
          max_entries,
          out,
          depth + 1,
        )
      }
      _ => out.push(rel)
    }
  }
}

///|
/// TTL-cached index build for the active workspace root.
pub async fn ConsoleRuntime::workspace_file_index(
  self : ConsoleRuntime,
) -> Array[String] {
  let now = @async.now()
  match self.file_index_cache {
    Some((built_at, entries)) if now - built_at < FILE_INDEX_TTL_MS =>
      return entries
    _ => ()
  }
  let entries : Array[String] = []
  workspace_index_walk(
    self.fs,
    self.active_cwd,
    "",
    workspace_mention_ignore_patterns(),
    FILE_INDEX_CAP,
    entries,
    0,
  )
  self.file_index_cache = Some((now, entries))
  entries
}

///|
/// Tiered `@`-mention ranking, identical in shape to the JS host's
/// rankFileMentionItems: basename exact > basename prefix > basename contains
/// > full-path contains; directories score +10 with a non-empty query; an
/// empty query ranks by depth. Non-matching entries drop out entirely —
/// fuzzy weak-first scoring flooded completions with noise.
fn rank_file_entries(
  entries : Array[String],
  query : String,
  limit : Int32,
) -> Array[Json] {
  let lowered = query.to_lower()
  let scored : Array[(Int32, Bool, String)] = []
  for entry in entries {
    let is_dir = file_entry_dir(entry)
    let clean = file_entry_clean(entry)
    let base = file_entry_basename(entry).to_lower()
    let full = clean.to_lower()
    let depth = clean.split("/").count() - 1
    let score : Int32 = if lowered is "" {
      (if is_dir { 120 } else { 100 }) - depth
    } else if base == lowered {
      100
    } else if base.has_prefix(lowered) {
      80
    } else if base.contains(lowered) {
      50
    } else if full.contains(lowered) {
      30
    } else {
      continue
    }
    let score = if is_dir && !(lowered is "") { score + 10 } else { score }
    scored.push((score, is_dir, entry))
  }
  scored.sort_by((a, b) => {
    let by_score = b.0 - a.0
    if by_score != 0 {
      by_score
    } else if a.1 != b.1 {
      if a.1 {
        -1
      } else {
        1
      }
    } else if a.2 < b.2 {
      -1
    } else {
      1
    }
  })
  let out : Array[Json] = []
  for entry in scored {
    if out.length() >= limit {
      break
    }
    out.push(
      Json::object(
        Map::from_array([
          ("path", Json::string(entry.2)),
          ("isDir", Json::boolean(entry.1)),
        ]),
      ),
    )
  }
  out
}

///|
/// `GET /api/files/search` — ranked `@`-mention candidates for the active
/// workspace. Transport shape stays minimal so the desktop adaptor can
/// serve the identical payload over IPC.
pub async fn ConsoleRuntime::file_suggestions_json(
  self : ConsoleRuntime,
  query : String,
  limit : Int32,
) -> Json {
  let entries = self.workspace_file_index()
  Json::object(
    Map::from_array([
      ("query", Json::string(query)),
      ("entries", Json::array(rank_file_entries(entries, query, limit))),
    ]),
  )
}

///|
test "rank_file_entries drops noise and ranks like the JS host" {
  let entries = [
    "src/runtime/main.mbt", "README.md", "server/", "web/src/routes/+page.svelte",
    ".github/workflows/ci.yml", "docs/readme-zh.md",
  ]
  let ranked = rank_file_entries(entries, "readme", 10)
  inspect(ranked.length(), content="2")
  json_inspect(ranked[0], content={ "path": "README.md", "isDir": false })
  json_inspect(ranked[1], content={
    "path": "docs/readme-zh.md",
    "isDir": false,
  })
  let none = rank_file_entries(entries, "zzz-no-match", 10)
  inspect(none.length(), content="0")
  let broad = rank_file_entries(entries, "", 3)
  json_inspect(broad[0], content={ "path": "server/", "isDir": true })
  let mbt = rank_file_entries(entries, "main.mbt", 10)
  json_inspect(mbt[0], content={
    "path": "src/runtime/main.mbt",
    "isDir": false,
  })
  let dirs = rank_file_entries(["api/", "api.go"], "api", 10)
  json_inspect(dirs[0], content={ "path": "api/", "isDir": true })
}

///|
async test "workspace_index_walk ignores segments and stays deterministic" {
  let root = @fs.tmpdir(prefix="cetas-idx-")
  let fs = @workspace.NativeWorkspaceFs()
  fs.mkdir(root + "/beta/inner", recursive=true) catch {
    _ => ()
  }
  fs.mkdir(root + "/node_modules/pkg", recursive=true) catch {
    _ => ()
  }
  fs.write_file(root + "/alpha.txt", "a") catch {
    _ => ()
  }
  fs.write_file(root + "/beta/inner/deep.txt", "d") catch {
    _ => ()
  }
  let out : Array[String] = []
  workspace_index_walk(
    fs,
    root,
    "",
    workspace_mention_ignore_patterns(),
    100,
    out,
    0,
  )
  // MoonBit's String ordering is length-before-code-units (the JS walk's
  // documented behavior), so this deterministic order is not alphabetical.
  assert_eq(out, ["beta/", "beta/inner/", "beta/inner/deep.txt", "alpha.txt"])
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}
