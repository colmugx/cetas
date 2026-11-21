///|
/// Extension-provided builtin scopes serialize for the API surface; the `Extra`
/// tag is an extension-internal label, never a public scope name.
test "skill scope labels serialize for the api surface" {
  assert_eq(skill_scope_label(Repository), "repository")
  assert_eq(skill_scope_label(User), "user")
  assert_eq(skill_scope_label(Extra("builtin")), "extension")
}

///|
/// `/api/skills` must mirror the session's composed catalog: the forme manuals
/// and the embedded PStack skill are extension-provided builtins no disk walk
/// can discover, so containment (never an exact list) is the contract.
async test "skills json carries the extension builtins the session composed" {
  @async.with_task_group(group => {
    let cwd = @fs.tmpdir(prefix="cetas-skills-ws-")
    let (runtime, _frames, home) = permission_mount(
      @permission.WorkspaceWrite,
      cwd,
      group,
    )
    let fields = match runtime.skills_json() {
      Json::Object(fields) => fields
      _ => abort("skills json must be an object")
    }
    let entries : Map[String, String] = Map([])
    match fields.get("skills") {
      Some(Json::Array(items)) =>
        for item in items {
          match item {
            Json::Object(entry) => {
              let name = match entry.get("name") {
                Some(Json::String(name)) => name
                _ => abort("skill entry must carry a name")
              }
              match entry.get("scope") {
                Some(Json::String(scope)) => entries[name] = scope
                _ => abort("skill entry must carry a scope")
              }
            }
            _ => abort("skill entry must be an object")
          }
        }
      _ => abort("skills json must carry a skills array")
    }
    for name in ["cetas-config", "poteto-mode"] {
      match entries.get(name) {
        Some(scope) => assert_eq(scope, "extension")
        None => fail("skills json is missing builtin skill '" + name + "'")
      }
    }
    runtime.shutdown_all()
    permission_fixture_cleanup(cwd)
    permission_fixture_cleanup(home)
  })
}
