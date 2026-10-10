///|
/// `GET /api/skills` — the composed skills catalog for the active
/// workspace: `$name`-mention candidates with their descriptions. Uses the
/// skills extension's public discovery (the same walk the session's skills
/// extension performs), so results match what the agent can activate.
pub async fn ConsoleRuntime::skills_json(self : ConsoleRuntime) -> Json {
  let handle = self.active().active()
  let discovery = @skills.SkillDiscovery(
    self.fs,
    cwd=handle.cwd,
    home=self.home,
  )
  let catalog = discovery.discover()
  let skills : Array[Json] = []
  for name in catalog.names() {
    let description = match catalog.find(name) {
      Some(descriptor) => descriptor.description
      None => ""
    }
    skills.push(
      Json::object(
        Map::from_array([
          ("name", Json::string(name)),
          ("description", Json::string(description)),
        ]),
      ),
    )
  }
  Json::object(Map::from_array([("skills", Json::array(skills))]))
}
