///|
/// `SkillScope` for the API surface: the `Extra` tag is an extension-internal
/// label, so every extension-provided builtin serializes as "extension".
fn skill_scope_label(scope : @skills.SkillScope) -> String {
  match scope {
    Repository => "repository"
    User => "user"
    Extra(_) => "extension"
  }
}

///|
/// `GET /api/skills` — the composed skills catalog for the active workspace:
/// `$name`-mention candidates with their descriptions. Reads the catalog the
/// session's skills extension composed (disk-discovered skills plus the
/// extension-provided builtins), not a fresh discovery walk, so results match
/// exactly what the agent can activate.
pub fn ConsoleRuntime::skills_json(self : ConsoleRuntime) -> Json {
  let workspace = self.active()
  let catalog = workspace.skills
  let skills : Array[Json] = []
  for name in catalog.names() {
    let (description, scope) = match catalog.find(name) {
      Some(descriptor) =>
        (descriptor.description, skill_scope_label(descriptor.scope))
      None => ("", "extension")
    }
    skills.push(
      Json::object(
        Map::from_array([
          ("name", Json::string(name)),
          ("description", Json::string(description)),
          ("scope", Json::string(scope)),
        ]),
      ),
    )
  }
  Json::object(Map::from_array([("skills", Json::array(skills))]))
}
