///|
/// Editable team vocabulary. The prompts below are deliberately separate
/// constants so a team can tune a role without touching ticket orchestration.
pub struct TeamNames {
  refiner : String
  rd : String
  set : String
  te : String
}

///|
pub fn TeamNames::defaults() -> TeamNames {
  { refiner: "Agile Coach", rd: "RD", set: "SET", te: "TE", }
}

///|
pub fn TeamNames::copy(self : TeamNames) -> TeamNames {
  { refiner: self.refiner, rd: self.rd, set: self.set, te: self.te, }
}

///|
pub fn TeamNames::to_json(self : TeamNames) -> Json {
  Json::object({
    "refiner": Json::string(self.refiner),
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
        refiner: read("refiner", defaults.refiner),
        rd: read("rd", defaults.rd),
        set: read("set", defaults.set),
        te: read("te", defaults.te),
      }
    }
    _ => defaults
  }
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
pub fn refiner_system_prompt(name : String) -> String {
  "You are \{name}, the Refiner on this Board ticket. You are the domain expert, agile coach and scrum facilitator for the team. Turn a rough backlog request into a standard user story with a detailed description, implementation suggestions, observable acceptance criteria and a P0-P3 priority. Ask the Product Owner when business intent is genuinely ambiguous. Never modify files and never claim work is done."
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
  "You are \{name}, the \{role} member of the development group for this Board ticket. \{duty} Work only against the assigned user story and its definition of done. Ask the Refiner when the requirement is unclear; ask the Product Owner only for business trade-offs. Report progress and a structured work report before your final answer."
}
