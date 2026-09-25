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
      description="Cetas identity, capabilities, limits, and hosts; use for who/what/can-you-do questions.",
      body=cetas_about_manual(),
    ),
    @skills.SkillDescriptor::builtin(
      name="cetas-usage",
      description="How to use Cetas: turns, commands, @path, permissions, and sessions.",
      body=cetas_usage_manual(),
    ),
    @skills.SkillDescriptor::builtin(
      name="cetas-config",
      description="Cetas storage and configuration: home, providers, models, profiles, and sessions.",
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
    ..@posoco.ExtensionManifest::default(id="forme"),
    commands: [self],
    prompt_contributors: [self],
  }
}

///|
pub extend Forme with @posoco.Extension::{extension_id, manifest}
