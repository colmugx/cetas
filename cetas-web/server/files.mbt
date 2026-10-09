///|
/// Workspace file index powering `@` mentions — relative paths from the
/// active workspace root; directories carry a trailing `/` (cetas-js
/// semantics: inserting a directory continues completion, a file ends the
/// mention with a space). Hidden entries are skipped by `readdir`; known
/// junk build dirs are pruned by name so the walk stays bounded.
const FILE_INDEX_TTL_MS : Int64 = 30_000

///|
const FILE_INDEX_CAP : Int = 4000

///|
const FILE_INDEX_MAX_DEPTH : Int = 12

///|
fn index_skip_dir(name : String) -> Bool {
  name
  is ("node_modules"
  | ".git"
  | "_build"
  | "target"
  | "dist"
  | "build"
  | ".next"
  | "venv"
  | ".venv"
  | "__pycache__"
  | "coverage"
  | ".mooncakes"
  | ".repos")
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
async fn probe_dir(path : String) -> Bool {
  try {
    ignore(@fs.readdir(path))
    true
  } catch {
    _ => false
  }
}

///|
/// TTL-cached index build. The walk is an explicit-stack BFS: every entry
/// is probed with `readdir` — success means directory (recorded with a
/// trailing `/` and expanded), failure means file. Errors on single dirs
/// are swallowed; the index stays best-effort by design.
async fn WebRuntime::workspace_file_index(self : WebRuntime) -> Array[String] {
  let now = @async.now()
  match self.file_index_cache {
    Some((built_at, entries)) if now - built_at < FILE_INDEX_TTL_MS =>
      return entries
    _ => ()
  }
  let root = self.active_cwd
  let entries : Array[String] = []
  let stack : Array[(String, Int)] = [("", 0)]
  while entries.length() < FILE_INDEX_CAP {
    let (rel, depth) = match stack.pop() {
      Some(top) => top
      None => break
    }
    let abs = if rel is "" { root } else { root + "/" + rel }
    let names = @fs.readdir(abs) catch { _ => continue }
    for name in names {
      if entries.length() >= FILE_INDEX_CAP || index_skip_dir(name) {
        continue
      }
      let child = if rel is "" { name } else { rel + "/" + name }
      let child_abs = root + "/" + child
      if probe_dir(child_abs) {
        entries.push(child + "/")
        if depth + 1 < FILE_INDEX_MAX_DEPTH {
          stack.push((child, depth + 1))
        }
      } else {
        entries.push(child)
      }
    }
  }
  self.file_index_cache = Some((now, entries))
  entries
}

///|
/// VS Code fuzzy-score ranking (bobzhang/fuzzyscore) over the index.
/// The scorer's weak-first mode returns small positive scores even without
/// a full match, so ranking is relative: everything is scored, then kept
/// only within half of the best score. Basename attempts get a bonus over
/// full-path attempts; the scorer is case-sensitive, so each entry is
/// tried as-is (camel bonuses intact) and lowercased. An empty query falls
/// back to the index's shallow-first walk order.
fn rank_file_entries(
  entries : Array[String],
  query : String,
  limit : Int,
) -> Array[Json] {
  let scored : Array[(Int, Bool, String)] = []
  if query is "" {
    for entry in entries {
      let depth = file_entry_clean(entry).split("/").count()
      scored.push((100 - depth, file_entry_dir(entry), entry))
    }
  } else {
    let lowered = query.to_lower()
    for entry in entries {
      let base = file_entry_basename(entry)
      let (s1, _) = @fuzzyscore.vscode_fuzzy_score_simple(query, base, true)
      let (s2, _) = @fuzzyscore.vscode_fuzzy_score_simple(
        lowered,
        base.to_lower(),
        true,
      )
      let (s3, _) = @fuzzyscore.vscode_fuzzy_score_simple(query, entry, true)
      let (s4, _) = @fuzzyscore.vscode_fuzzy_score_simple(
        lowered,
        entry.to_lower(),
        true,
      )
      let base_score = if s1 > s2 { s1 } else { s2 }
      let path_score = if s3 > s4 { s3 } else { s4 }
      let score = if base_score > 0 { base_score + 20 } else { path_score }
      scored.push((score, file_entry_dir(entry), entry))
    }
  }
  // Relative floor: weak-first noise lands far below the best candidate,
  // so half-of-best keeps the honest matches.
  let best = scored.fold(init=0, (best, entry) => {
    if entry.0 > best {
      entry.0
    } else {
      best
    }
  })
  let floor = best / 2
  let kept = scored.filter(entry => entry.0 >= floor && entry.0 > 0)
  kept.sort_by((a, b) => {
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
  for entry in kept {
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
async fn WebRuntime::file_suggestions_json(
  self : WebRuntime,
  query : String,
  limit : Int,
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
test "rank_file_entries keeps relative-floor matches" {
  let entries = [
    "src/runtime/main.mbt", "README.md", "server/", "web/src/routes/+page.svelte",
  ]
  // "readme" truly matches only README.md (168); weak-first noise lands at
  // 45-82, below the half-of-best floor.
  let ranked = rank_file_entries(entries, "readme", 10)
  inspect(ranked.length(), content="1")
  json_inspect(ranked[0], content={ "path": "README.md", "isDir": false })
  // Empty query = shallow-first walk order, directories ahead.
  let broad = rank_file_entries(entries, "", 10)
  json_inspect(broad[0], content={ "path": "server/", "isDir": true })
  let mbt = rank_file_entries(entries, "main.mbt", 10)
  json_inspect(mbt[0], content={
    "path": "src/runtime/main.mbt",
    "isDir": false,
  })
}
