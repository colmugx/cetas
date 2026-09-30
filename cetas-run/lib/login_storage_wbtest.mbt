///|
priv struct LoginWriteFailureFs {
  inner : FakeFs
  fail_path : String
}

///|
impl @workspace.WorkspaceFs for LoginWriteFailureFs with fn exists(self, path) {
  self.inner.files.contains(path) || self.inner.dirs.contains(path)
}

///|
impl @workspace.WorkspaceFs for LoginWriteFailureFs with fn kind(
  _self,
  _path,
  follow_symlink~,
) {
  ignore(follow_symlink)
  @workspace.WorkspaceFileKind::File
}

///|
impl @workspace.WorkspaceFs for LoginWriteFailureFs with fn read_file(
  self,
  path,
) {
  match self.inner.files.get(path) {
    Some(text) => text
    None => raise @workspace.WorkspaceFsError::WorkspaceFsError("missing")
  }
}

///|
impl @workspace.WorkspaceFs for LoginWriteFailureFs with fn write_file(
  self,
  path,
  text,
) {
  self.inner.files[path] = text
}

///|
impl @workspace.WorkspaceFs for LoginWriteFailureFs with fn write_file_atomic(
  self,
  path,
  text,
) {
  if path == self.fail_path {
    raise @workspace.WorkspaceFsError::WorkspaceFsError(
      "write failed secret-fixture",
    )
  }
  self.inner.files[path] = text
}

///|
impl @workspace.WorkspaceFs for LoginWriteFailureFs with fn remove(self, path) {
  ignore(self.inner.files.remove(path))
}

///|
impl @workspace.WorkspaceFs for LoginWriteFailureFs with fn rename(
  _self,
  _from,
  _to,
  replace~,
) {
  ignore(replace)
}

///|
impl @workspace.WorkspaceFs for LoginWriteFailureFs with fn realpath(
  _self,
  path,
) {
  path
}

///|
impl @workspace.WorkspaceFs for LoginWriteFailureFs with fn readdir(
  _self,
  _path,
  include_hidden~,
) {
  ignore(include_hidden)
  []
}

///|
impl @workspace.WorkspaceFs for LoginWriteFailureFs with fn walk(
  _self,
  _root,
  _callback,
) {

}

///|
impl @workspace.WorkspaceFs for LoginWriteFailureFs with fn mkdir(
  self,
  path,
  recursive~,
) {
  ignore(recursive)
  self.inner.dirs.add(path)
}

///|
async test "login persistence failure preserves old credential and never refreshes" {
  let inner = FakeFs()
  let path = "/login-home/.cetas/credentials/openai.json"
  let store = @credentials.FileProviderCredentialStore(
    inner,
    @cetas_core.credentials_path("/login-home"),
  )
  store.write("openai", login_oauth_fixture())
  let old = inner.files[path]
  let fs : LoginWriteFailureFs = { inner, fail_path: path, }
  let probe = LoginProbe()
  let notes : Array[String] = []
  let result = try
    login_fixture(
      fs,
      LoginPrompt(["api_key", "sk-test-secret-fixture"]),
      probe,
      notes,
    )
  catch {
    err => err.to_string()
  } noraise {
    _ => "unexpected success"
  }
  assert_true(result.contains("could not be saved"))
  assert_false(result.contains("secret-fixture"))
  assert_eq(probe.calls, ["login:openai:api_key"])
  assert_eq(probe.snapshots.length(), 0)
  assert_eq(inner.files[path], old)
  assert_eq(notes.length(), 0)
}

///|
async test "login cache write failure retains saved authentication without saving a model" {
  let inner = FakeFs()
  let fs : LoginWriteFailureFs = {
    inner,
    fail_path: "/login-home/.cetas/model_lists.json",
  }
  let probe = LoginProbe()
  let notes : Array[String] = []
  let result = try
    login_fixture(
      fs,
      LoginPrompt(["api_key", "sk-test-secret-fixture"]),
      probe,
      notes,
    )
  catch {
    err => err.to_string()
  } noraise {
    _ => "unexpected success"
  }
  assert_true(result.contains("Authentication saved"))
  assert_true(result.contains("could not be cached"))
  assert_false(result.contains("secret-fixture"))
  assert_true(
    inner.files.contains("/login-home/.cetas/credentials/openai.json"),
  )
  assert_false(inner.files.contains("/login-home/.cetas/settings.json"))
  assert_login_notes_safe(notes)
}

///|
async test "login model write failure retains saved authentication and cached catalog" {
  let inner = FakeFs()
  let fs : LoginWriteFailureFs = {
    inner,
    fail_path: "/login-home/.cetas/settings.json",
  }
  let result = try
    login_fixture(
      fs,
      LoginPrompt(["api_key", "sk-test-secret-fixture"]),
      LoginProbe(),
      [],
    )
  catch {
    err => err.to_string()
  } noraise {
    _ => "unexpected success"
  }
  assert_true(result.contains("Authentication saved"))
  assert_true(result.contains("model selection could not be saved"))
  assert_false(result.contains("secret-fixture"))
  assert_true(
    inner.files.contains("/login-home/.cetas/credentials/openai.json"),
  )
  assert_true(inner.files.contains("/login-home/.cetas/model_lists.json"))
}
