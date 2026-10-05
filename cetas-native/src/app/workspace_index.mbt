/// Native workspace file index for @path completion.
///
/// This is the native equivalent of cetas-js/lib/workspace_index.mbt. The
/// index is composition-scoped and bounded so per-keystroke completion stays
/// purely in-memory.

///|
fn native_workspace_mention_ignore_patterns() -> Array[String] {
  ["node_modules", ".git", ".hg", ".svn", "_build", "target"]
}

///|
async fn native_workspace_file_index(
  fs : &@workspace.WorkspaceFs,
  root : String,
  max_entries? : Int = 20000,
) -> Array[String] noraise {
  let out : Array[String] = []
  native_workspace_index_walk(
    fs,
    root,
    "",
    native_workspace_mention_ignore_patterns(),
    max_entries,
    out,
    0,
  )
  out
}

///|
async fn native_workspace_index_walk(
  fs : &@workspace.WorkspaceFs,
  dir : String,
  rel_prefix : String,
  ignore_patterns : Array[String],
  max_entries : Int,
  out : Array[String],
  depth : Int,
) -> Unit noraise {
  if out.length() >= max_entries || depth > 32 {
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
        native_workspace_index_walk(
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
