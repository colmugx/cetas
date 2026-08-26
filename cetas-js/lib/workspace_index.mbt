///|
/// Ignore patterns for the `@`-mention file index. Mirrors the
/// `WorkspacePolicy::checked` defaults so completion offers the same tree the
/// glob/read tools can see.
fn workspace_mention_ignore_patterns() -> Array[String] {
  ["node_modules", ".git", ".hg", ".svn", "_build", "target"]
}

///|
/// Build the `@`-mention file index for `root`: files and directories as
/// paths relative to `root`, directories carrying a trailing `/`. Entries are
/// sorted per directory for deterministic output; unreadable directories and
/// unstatable entries are skipped so one broken subtree never blanks the
/// index. Symlinked directories are not followed (non-following stat), and
/// the whole walk is bounded by `max_entries`.
async fn workspace_file_index(
  fs : &@workspace.WorkspaceFs,
  root : String,
  ignore_patterns? : Array[String] = workspace_mention_ignore_patterns(),
  max_entries? : Int = 20000,
) -> Array[String] noraise {
  let out : Array[String] = []
  workspace_index_walk(fs, root, "", ignore_patterns, max_entries, out, 0)
  out
}

///|
/// Depth-first recursion for `workspace_file_index`. `rel_prefix` is the
/// accumulated relative path ("" or ending in "/"); `depth` bounds pathological
/// nesting on top of the symlink no-follow rule.
async fn workspace_index_walk(
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
  // `String`'s Compare orders by length before code units, so this is not
  // alphabetical — it only pins a deterministic output order; the host ranks
  // entries itself.
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
/// Async JS export: the workspace file index for `@`-mention autocomplete.
/// Returns a JSON array of paths relative to `config.cwd`; directories carry
/// a trailing `/` so the host can offer continued completion inside them.
/// Stateless and Agent-free — the host may call it before setup completes and
/// mid-turn, caching the result on its side (one bounded walk per refresh).
pub fn cetas_js_list_workspace_files(
  config : CetasJsConfig,
) -> @js_async.Promise[String] {
  @js_async.Promise::from_async() <| () => {
    let files = workspace_file_index(
      @workspace.JsWorkspaceFs(),
      config.cwd,
      ignore_patterns=workspace_mention_ignore_patterns(),
      max_entries=20000,
    )
    Json::array(files.map(fn(path) { Json::string(path) })).stringify()
  }
}
