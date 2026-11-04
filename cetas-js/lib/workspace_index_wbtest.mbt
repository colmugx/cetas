///|
/// In-memory WorkspaceFs for index tests: `dirs` maps absolute directory to
/// entry names, `kinds` maps absolute path to kind. Methods the index never
/// touches raise, so a silent success cannot fake a pass.
struct FakeIndexFs {
  dirs : Map[String, Array[String]]
  kinds : Map[String, @workspace.WorkspaceFileKind]
  /// Directories whose readdir raises; simulates permission failures.
  unreadable : Array[String]
}

///|
fn FakeIndexFs::make(
  dirs~ : Array[(String, Array[String])],
  file_kinds~ : Array[String],
  dir_kinds~ : Array[String],
  unreadable~ : Array[String] = [],
) -> FakeIndexFs {
  let kind_map : Map[String, @workspace.WorkspaceFileKind] = Map::from_array([])
  for path in file_kinds {
    kind_map[path] = File
  }
  for path in dir_kinds {
    kind_map[path] = Dir
  }
  { dirs: Map::from_array(dirs), kinds: kind_map, unreadable, }
}

///|
fn index_fs_error(op : String) -> @workspace.WorkspaceFsError {
  @workspace.WorkspaceFsError::WorkspaceFsError("\{op} not implemented")
}

///|
pub impl @workspace.WorkspaceFs for FakeIndexFs with fn exists(_self, path) -> Bool raise @workspace.WorkspaceFsError {
  let _ = path
  raise index_fs_error("exists")
}

///|
pub impl @workspace.WorkspaceFs for FakeIndexFs with fn kind(
  self,
  path,
  follow_symlink~,
) -> @workspace.WorkspaceFileKind raise @workspace.WorkspaceFsError {
  let _ = follow_symlink
  match self.kinds.get(path) {
    Some(kind) => kind
    None => raise index_fs_error("kind")
  }
}

///|
pub impl @workspace.WorkspaceFs for FakeIndexFs with fn read_file(_self, path) -> String raise @workspace.WorkspaceFsError {
  let _ = path
  raise index_fs_error("read_file")
}

///|
pub impl @workspace.WorkspaceFs for FakeIndexFs with fn write_file(
  _self,
  path,
  content,
) -> Unit raise @workspace.WorkspaceFsError {
  let _ = (path, content)
  raise index_fs_error("write_file")
}

///|
pub impl @workspace.WorkspaceFs for FakeIndexFs with fn write_file_atomic(
  _self,
  path,
  content,
) -> Unit raise @workspace.WorkspaceFsError {
  let _ = (path, content)
  raise index_fs_error("write_file_atomic")
}

///|
pub impl @workspace.WorkspaceFs for FakeIndexFs with fn remove(_self, path) -> Unit raise @workspace.WorkspaceFsError {
  let _ = path
  raise index_fs_error("remove")
}

///|
pub impl @workspace.WorkspaceFs for FakeIndexFs with fn rename(
  _self,
  from,
  to_,
  replace~,
) -> Unit raise @workspace.WorkspaceFsError {
  let _ = (from, to_, replace)
  raise index_fs_error("rename")
}

///|
pub impl @workspace.WorkspaceFs for FakeIndexFs with fn realpath(_self, path) -> String raise @workspace.WorkspaceFsError {
  let _ = path
  raise index_fs_error("realpath")
}

///|
pub impl @workspace.WorkspaceFs for FakeIndexFs with fn readdir(
  self,
  path,
  include_hidden~,
) -> Array[String] raise @workspace.WorkspaceFsError {
  let _ = include_hidden
  if self.unreadable.contains(path) {
    raise index_fs_error("readdir")
  }
  match self.dirs.get(path) {
    Some(entries) => entries
    None => raise index_fs_error("readdir")
  }
}

///|
pub impl @workspace.WorkspaceFs for FakeIndexFs with fn walk(
  _self,
  root,
  callback,
) -> Unit raise @workspace.WorkspaceFsError {
  let _ = (root, callback)
  raise index_fs_error("walk")
}

///|
pub impl @workspace.WorkspaceFs for FakeIndexFs with fn mkdir(
  _self,
  path,
  recursive~,
) -> Unit raise @workspace.WorkspaceFsError {
  let _ = (path, recursive)
  raise index_fs_error("mkdir")
}

///|
async test "workspace_file_index skips unreadable directories" {
  let fs = FakeIndexFs::make(
    dirs=[("/repo", ["a.mbt", "secret"]), ("/repo/secret", ["s.mbt"])],
    file_kinds=["/repo/a.mbt", "/repo/secret/s.mbt"],
    dir_kinds=["/repo/secret"],
    unreadable=["/repo/secret"],
  )
  let index = workspace_file_index(fs, "/repo")
  inspect(index.length(), content="2")
  inspect(index[0], content="a.mbt")
  inspect(index[1], content="secret/")
}

///|
async test "workspace_file_index caps collected entries" {
  let fs = FakeIndexFs::make(
    dirs=[("/repo", ["a.mbt", "b.mbt", "c.mbt"])],
    file_kinds=["/repo/a.mbt", "/repo/b.mbt", "/repo/c.mbt"],
    dir_kinds=[],
  )
  let index = workspace_file_index(fs, "/repo", max_entries=2)
  inspect(index.length(), content="2")
  inspect(index[0], content="a.mbt")
  inspect(index[1], content="b.mbt")
}

///|
/// The default mention-ignore patterns must drop `node_modules` (and friends)
/// from the `@`-mention index while ordinary files still surface. Membership
/// only — the host ranks entries itself, so order is not a contract here.
async test "workspace_file_index honors default ignore patterns" {
  let fs = FakeIndexFs::make(
    dirs=[
      ("/repo", ["src", "node_modules", "README.md"]),
      ("/repo/src", ["main.mbt"]),
      ("/repo/node_modules", ["chalk"]),
      ("/repo/node_modules/chalk", ["index.js"]),
    ],
    file_kinds=[
      "/repo/README.md", "/repo/src/main.mbt", "/repo/node_modules/chalk/index.js",
    ],
    dir_kinds=["/repo/src", "/repo/node_modules", "/repo/node_modules/chalk"],
  )
  let index = workspace_file_index(fs, "/repo")
  assert_false(index.contains("node_modules/"))
  assert_false(index.contains("node_modules/chalk/"))
  assert_true(index.contains("README.md"))
  assert_true(index.contains("src/"))
  assert_true(index.contains("src/main.mbt"))
}

///|
pub extend FakeIndexFs with @workspace.WorkspaceFs::{
  exists,
  kind,
  mkdir,
  read_file,
  readdir,
  realpath,
  remove,
  rename,
  walk,
  write_file,
  write_file_atomic,
}
