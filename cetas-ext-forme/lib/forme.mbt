///|
/// forme.mbt — Cetas self-description extension.
///
/// Two surfaces, one struct: the /help command (deterministic, no model
/// turn) and the prompt routing note that steers "what is cetas / how do I"
/// questions to the built-in manual skills. The manuals themselves are
/// inline `SkillDescriptor`s merged into the host's skills extension by
/// cetas-core, so they ride the normal activate_skill disclosure path.
pub(all) struct Forme {
  /// Host-specific quick-reference lines (keybindings, input conventions)
  /// appended to /help output. Hosts know their own keys; cetas does not.
  host_note : String?
}

///|
pub fn Forme::Forme(host_note? : String? = None) -> Forme {
  { host_note, }
}

///|
/// The built-in product manuals as inline skills. Descriptions are
/// trigger-condition phrasing so the startup catalog routes capability,
/// usage, and configuration questions to the right manual.
pub fn builtin_manual_skills() -> Array[@skills.SkillDescriptor] {
  [
    @skills.SkillDescriptor::builtin(
      name="cetas-about",
      description="What cetas is, what it can and cannot do, and which hosts exist. Use when the user asks what cetas/this agent is or what it can do for them.",
      body=cetas_about_manual(),
    ),
    @skills.SkillDescriptor::builtin(
      name="cetas-usage",
      description="How to use cetas: turns, slash commands, @path mentions, permission modes, session resume. Use when the user asks how to do something with cetas or hits a usage problem.",
      body=cetas_usage_manual(),
    ),
    @skills.SkillDescriptor::builtin(
      name="cetas-config",
      description="Where cetas keeps state (~/.cetas, settings.json, sessions) and how to change providers, models, and profiles. Use when the user asks about configuration or storage.",
      body=cetas_config_manual(),
    ),
  ]
}

///|
pub impl @posoco.Extension for Forme with fn extension_id(_self) -> String {
  "forme"
}

///|
pub impl @posoco.Extension for Forme with fn manifest(self : Forme) -> @posoco.ExtensionManifest {
  {
    ..@posoco.ExtensionManifest::empty(id="forme"),
    commands: [self],
    prompt_contributors: [self],
  }
}

///|
pub extend Forme with @posoco.Extension::{extension_id, manifest}
