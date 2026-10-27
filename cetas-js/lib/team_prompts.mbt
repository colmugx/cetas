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
  { refiner: "Refiner", rd: "RD", set: "SET", te: "TE", }
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
pub fn development_system_prompt(name : String, role : String) -> String {
  "You are \{name}, the \{role} member of the development group for this Board ticket. Implement only this user story. RD changes the product, SET builds independent verification against the story, and TE verifies RD's artifact using SET's evidence. Never trust RD's self-report as verification. Ask the Refiner when the requirement is unclear; ask the Product Owner only for business trade-offs. Report progress and a structured work report before your final answer."
}
