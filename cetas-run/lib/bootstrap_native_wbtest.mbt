///|
#cfg(target="native")
async test "bootstrap leaves existing symlinks including dangling links untouched" {
  // Windows can require administrator privileges to create a symlink.
  if @env.get_env_var("OS") == Some("Windows_NT") {
    return
  }
  let home = @fs.tmpdir(prefix="cetas-run-symlink")
  defer @fs.rmdir(home, recursive=true)
  let dir = @cetas_core.cetas_dir(home)
  let path = @cetas_core.settings_path(home)
  @fs.mkdir(dir)
  let target = home + "/target"
  @fs.symlink(target~, path)
  assert_false(create_minimal_settings(dir, path))
  assert_false(@fs.exists(target))
  assert_true(@fs.kind(path, follow_symlink=false) is @fs.SymLink)
  @fs.write_file(target, "user settings")
  assert_false(create_minimal_settings(dir, path))
  assert_eq(@fs.read_file(target).text(), "user settings")
  assert_true(@fs.kind(path, follow_symlink=false) is @fs.SymLink)
}
