///|
/// forme.mbt — Cetas self-description extension.
///
/// Two surfaces, one struct: the /help command (deterministic, no model
/// turn) and the prompt routing note that steers "what is cetas / how do I"
/// questions to the built-in manual skills. The manuals themselves are
/// inline `SkillDescriptor`s merged into the host's skills extension by the
/// host recipe, so they ride the normal activate_skill disclosure path.
pub(all) struct Forme {
  /// Host-specific quick-reference lines (keybindings, input conventions)
  /// appended to /help output. Hosts know their own keys; cetas does not.
  host_note : String?
  /// Host-provided distribution and version line (e.g. "0.10.9 (npm)").
  /// Surfaced in /help and interpolated into the cetas-about manual so the
  /// model can state the running version instead of guessing.
  version_note : String?
}

///|
pub fn Forme::Forme(
  host_note~ : String? = None,
  version_note~ : String? = None,
) -> Forme {
  { host_note, version_note, }
}

///|
/// The built-in product manuals as inline skills, ordered by forme's
/// priority: configuring cetas first, day-to-day usage second, identity
/// last. Descriptions are trigger-condition phrasing so the startup catalog
/// routes setup/configuration, usage, and capability questions to the right
/// manual.
pub fn Forme::builtin_manual_skills(
  self : Forme,
) -> Array[@skills.SkillDescriptor] {
  [
    @skills.SkillDescriptor::builtin(
      name="cetas-config",
      description="Cetas storage and configuration: the cetas home, ~/.cetas/settings.json, providers, models, and sessions. Use for any setup or configuration task.",
      body=cetas_config_manual(),
    ),
    @skills.SkillDescriptor::builtin(
      name="cetas-usage",
      description="How to use Cetas: turns, commands, @path, permissions, and sessions. Use for how-to-drive-cetas questions.",
      body=cetas_usage_manual(),
    ),
    @skills.SkillDescriptor::builtin(
      name="cetas-about",
      description="Cetas identity, capabilities, limits, hosts, and running version; use for who/what/can-you-do questions.",
      body=cetas_about_manual(version_note=self.version_note),
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
