///|
/// Editable team vocabulary. The prompts below are deliberately separate
/// constants so a team can tune a role without touching ticket orchestration.
pub struct TeamNames {
  po : String
  sm : String
  rd : String
  set : String
  te : String
}

///|
pub fn TeamNames::defaults() -> TeamNames {
  { po: "Product Owner", sm: "Scrum Master", rd: "RD", set: "SET", te: "TE", }
}

///|
pub fn TeamNames::copy(self : TeamNames) -> TeamNames {
  { po: self.po, sm: self.sm, rd: self.rd, set: self.set, te: self.te, }
}

///|
pub fn TeamNames::to_json(self : TeamNames) -> Json {
  Json::object({
    "po": Json::string(self.po),
    "sm": Json::string(self.sm),
    "rd": Json::string(self.rd),
    "set": Json::string(self.set),
    "te": Json::string(self.te),
  })
}

///|
pub fn TeamNames::from_json(value : Json) -> TeamNames {
  let defaults = TeamNames::defaults()
  let clean = (text : String, fallback : String) => {
    let mut out = ""
    for ch in text.trim() {
      if ch != '\n' && ch != '\r' && ch != '\t' && out.length() < 40 {
        out = out + ch.to_string()
      }
    }
    if out == "" {
      fallback
    } else {
      out
    }
  }
  match value {
    Object(fields) => {
      let read = (key, fallback) => {
        match fields.get(key) {
          Some(String(text)) => clean(text, fallback)
          _ => fallback
        }
      }
      {
        po: read(
          "po",
          match fields.get("refiner") {
            Some(String(value)) => clean(value, defaults.po)
            _ => defaults.po
          },
        ),
        sm: read("sm", defaults.sm),
        rd: read("rd", defaults.rd),
        set: read("set", defaults.set),
        te: read("te", defaults.te),
      }
    }
    _ => defaults
  }
}

///|
/// MCP access is a per-role capability, not a Product Owner privilege: a
/// frontend TE may need a browser MCP while an RD needs GitHub. `all` means
/// every host-configured server; `servers` is used only when `all` is false.
pub struct TeamMcp {
  enabled : Bool
  all : Bool
  servers : Array[String]
  tools : Array[String]
}

///|
pub fn TeamMcp::defaults() -> TeamMcp {
  { enabled: false, all: true, servers: [], tools: [], }
}

///|
pub fn TeamMcp::to_json(self : TeamMcp) -> Json {
  Json::object({
    "enabled": Json::boolean(self.enabled),
    "all": Json::boolean(self.all),
    "servers": Json::array(self.servers.map(Json::string)),
    "tools": Json::array(self.tools.map(Json::string)),
  })
}

///|
pub fn TeamMcp::from_json(value : Json) -> TeamMcp {
  let defaults = TeamMcp::defaults()
  match value {
    Object(fields) => {
      let enabled = match fields.get("enabled") {
        Some(Json::True) => true
        Some(Json::False) => false
        _ => defaults.enabled
      }
      let all = match fields.get("all") {
        Some(Json::True) => true
        Some(Json::False) => false
        _ => defaults.all
      }
      let servers : Array[String] = []
      match fields.get("servers") {
        Some(Array(items)) =>
          for item in items {
            match item {
              String(name) if name != "" && !servers.contains(name) =>
                servers.push(name)
              _ => ()
            }
          }
        _ => ()
      }
      let tools : Array[String] = []
      match fields.get("tools") {
        Some(Array(items)) =>
          for item in items {
            match item {
              String(name) if name != "" && !tools.contains(name) =>
                tools.push(name)
              _ => ()
            }
          }
        _ => ()
      }
      { enabled, all, servers, tools, }
    }
    _ => defaults
  }
}

///|
/// One fixed set of roles; absent roles read as disabled with all servers.
pub fn default_team_mcp() -> Map[String, TeamMcp] {
  Map::from_array([
    ("po", TeamMcp::defaults()),
    ("sm", TeamMcp::defaults()),
    ("rd", TeamMcp::defaults()),
    ("set", TeamMcp::defaults()),
    ("te", TeamMcp::defaults()),
  ])
}

///|
pub fn TeamMcp::to_json_map(mcp : Map[String, TeamMcp]) -> Json {
  let fields : Map[String, Json] = Map([])
  for role in ["po", "sm", "rd", "set", "te"] {
    fields[role] = match mcp.get(role) {
      Some(value) => value.to_json()
      None => TeamMcp::defaults().to_json()
    }
  }
  Json::object(fields)
}

///|
pub fn TeamMcp::from_json_map(value : Json) -> Map[String, TeamMcp] {
  let out = default_team_mcp()
  match value {
    Object(fields) => {
      for role in ["po", "sm", "rd", "set", "te"] {
        match fields.get(role) {
          Some(item) => out[role] = TeamMcp::from_json(item)
          None => ()
        }
      }
      match fields.get("refiner") {
        Some(item) if !fields.contains("po") =>
          out["po"] = TeamMcp::from_json(item)
        _ => ()
      }
    }
    _ => ()
  }
  out
}

///|
/// Per-role skills. Skills are instruction packs, not external tools; `all`
/// means every host-discovered skill.
pub struct TeamSkills {
  enabled : Bool
  all : Bool
  skills : Array[String]
}

///|
pub fn TeamSkills::defaults() -> TeamSkills {
  { enabled: false, all: true, skills: [], }
}

///|
pub fn TeamSkills::to_json(self : TeamSkills) -> Json {
  Json::object({
    "enabled": Json::boolean(self.enabled),
    "all": Json::boolean(self.all),
    "skills": Json::array(self.skills.map(Json::string)),
  })
}

///|
pub fn TeamSkills::from_json(value : Json) -> TeamSkills {
  let defaults = TeamSkills::defaults()
  match value {
    Object(fields) => {
      let enabled = match fields.get("enabled") {
        Some(Json::True) => true
        Some(Json::False) => false
        _ => defaults.enabled
      }
      let all = match fields.get("all") {
        Some(Json::True) => true
        Some(Json::False) => false
        _ => defaults.all
      }
      let skills : Array[String] = []
      match fields.get("skills") {
        Some(Array(items)) =>
          for item in items {
            match item {
              String(name) if name != "" && !skills.contains(name) =>
                skills.push(name)
              _ => ()
            }
          }
        _ => ()
      }
      { enabled, all, skills, }
    }
    _ => defaults
  }
}

///|
pub fn default_team_skills() -> Map[String, TeamSkills] {
  Map::from_array([
    ("po", TeamSkills::defaults()),
    ("sm", TeamSkills::defaults()),
    ("rd", TeamSkills::defaults()),
    ("set", TeamSkills::defaults()),
    ("te", TeamSkills::defaults()),
  ])
}

///|
pub fn TeamSkills::to_json_map(skills : Map[String, TeamSkills]) -> Json {
  let fields : Map[String, Json] = Map([])
  for role in ["po", "sm", "rd", "set", "te"] {
    fields[role] = match skills.get(role) {
      Some(value) => value.to_json()
      None => TeamSkills::defaults().to_json()
    }
  }
  Json::object(fields)
}

///|
pub fn TeamSkills::from_json_map(value : Json) -> Map[String, TeamSkills] {
  let out = default_team_skills()
  match value {
    Object(fields) => {
      for role in ["po", "sm", "rd", "set", "te"] {
        match fields.get(role) {
          Some(item) => out[role] = TeamSkills::from_json(item)
          None => ()
        }
      }
      match fields.get("refiner") {
        Some(item) if !fields.contains("po") =>
          out["po"] = TeamSkills::from_json(item)
        _ => ()
      }
    }
    _ => ()
  }
  out
}

///|
/// Durable Board team configuration. The host owns the file; the Board owns
/// the semantics. Paths and skill bodies never enter this record.
pub struct TeamConfig {
  names : TeamNames
  mcp : Map[String, TeamMcp]
  skills : Map[String, TeamSkills]
  profile : WorkProfile
}

///|
pub fn TeamConfig::defaults() -> TeamConfig {
  {
    names: TeamNames::defaults(),
    mcp: default_team_mcp(),
    skills: default_team_skills(),
    profile: WorkProfile::software(),
  }
}

///|
pub fn TeamConfig::to_json(self : TeamConfig) -> Json {
  Json::object({
    "names": self.names.to_json(),
    "mcp": TeamMcp::to_json_map(self.mcp),
    "skills": TeamSkills::to_json_map(self.skills),
    "profile": self.profile.to_json(),
  })
}

///|
pub fn TeamConfig::from_json(value : Json) -> TeamConfig {
  let defaults = TeamConfig::defaults()
  match value {
    Object(fields) => {
      let names = match fields.get("names") {
        Some(value) => TeamNames::from_json(value)
        None => defaults.names
      }
      let mcp = match fields.get("mcp") {
        Some(value) => TeamMcp::from_json_map(value)
        None => defaults.mcp
      }
      let skills = match fields.get("skills") {
        Some(value) => TeamSkills::from_json_map(value)
        None => defaults.skills
      }
      let profile = match fields.get("profile") {
        Some(value) =>
          match value {
            Object(profile) =>
              match profile.get("id") {
                Some(String(id)) => WorkProfile::from_id(id)
                _ => defaults.profile
              }
            _ => defaults.profile
          }
        None => defaults.profile
      }
      { names, mcp, skills, profile, }
    }
    _ => defaults
  }
}

///|
/// One host-discovered skill, projected to the Board without paths or bodies.
pub struct BoardSkill {
  name : String
  description : String
}

///|
pub fn BoardSkill::to_json(self : BoardSkill) -> Json {
  Json::object({
    "name": Json::string(self.name),
    "description": Json::string(self.description),
  })
}

///|
pub fn BoardSkill::from_descriptor(
  descriptor : @skills.SkillDescriptor,
) -> BoardSkill {
  { name: descriptor.name, description: descriptor.description, }
}

///|
/// A domain profile changes vocabulary, not the internal role ids. RD/SET/TE
/// remain the stable accountability slots; the profile says what they produce.
pub struct WorkProfile {
  id : String
  label : String
  work_product : String
}

///|
pub fn WorkProfile::software() -> WorkProfile {
  { id: "software", label: "Software", work_product: "product change", }
}

///|
pub fn WorkProfile::document() -> WorkProfile {
  { id: "document", label: "Document", work_product: "written deliverable", }
}

///|
pub fn WorkProfile::analysis() -> WorkProfile {
  {
    id: "analysis",
    label: "Analysis",
    work_product: "analysis and recommendation",
  }
}

///|
pub fn WorkProfile::from_id(id : String) -> WorkProfile {
  match id {
    "document" => WorkProfile::document()
    "analysis" => WorkProfile::analysis()
    _ => WorkProfile::software()
  }
}

///|
pub fn work_profiles() -> Array[WorkProfile] {
  [WorkProfile::software(), WorkProfile::document(), WorkProfile::analysis()]
}

///|
pub fn WorkProfile::to_json(self : WorkProfile) -> Json {
  Json::object({
    "id": Json::string(self.id),
    "label": Json::string(self.label),
    "work_product": Json::string(self.work_product),
  })
}

///|
/// Last path segment only. A Board title must not leak the full checkout path.
pub fn project_name(cwd : String) -> String {
  let trimmed = cwd.trim().to_owned()
  if trimmed.is_empty() {
    return "workspace"
  }
  let mut name = ""
  for ch in trimmed {
    if ch == '/' || ch == '\\' {
      name = ""
    } else {
      name = name + ch.to_string()
    }
  }
  if name == "" {
    "workspace"
  } else {
    name
  }
}

///|
pub fn po_system_prompt(name : String) -> String {
  "You are \{name}, the Product Owner on this Board ticket. Turn a rough backlog request into a standard user story written as exactly three lines: the role, what the user wants, and why. Then add a detailed description, implementation suggestions, observable acceptance criteria and a P0-P3 priority. Ask the Customer when business intent is genuinely ambiguous. Never modify files and never claim work is done."
}

///|
pub fn development_system_prompt(
  name : String,
  role : String,
  profile : WorkProfile,
) -> String {
  let duty = match role {
    "rd" => "Produce the \{profile.work_product}."
    "set" =>
      "Design independent checks that prove the \{profile.work_product} satisfies the story."
    _ =>
      "Verify the \{profile.work_product} using SET's independent evidence, not RD's self-report."
  }
  "You are \{name}, the \{role} member of the development group for this Board ticket. \{duty} Work only against the assigned user story and its definition of done. Ask the Product Owner when the requirement or DoD is unclear; ask the Customer only for original business intent or trade-offs. Report progress and a structured work report before your final answer."
}
