///|
/// Built-in manuals for the Memoh composition. Reuse the product-wide identity
/// and usage manuals, but replace the generic Cetas configuration manual with
/// one that reflects Memoh's independent provider home and ownership boundary.
pub fn memoh_builtin_skills() -> Array[@skills.SkillDescriptor] {
  let manuals : Array[@skills.SkillDescriptor] = []
  for skill in @forme.builtin_manual_skills() {
    if skill.name != "cetas-config" {
      manuals.push(skill)
    }
  }
  manuals.push(
    @skills.SkillDescriptor::builtin(
      name="cetas-memoh-config",
      description="Use when configuring Cetas inside Memoh, providers, models, credentials, or explaining what Memoh owns.",
      body="Cetas-Memoh is independently configured from generic Cetas. " +
      "Its provider home is CETAS_MEMOH_HOME, otherwise $HOME/.cetas-memoh; " +
      "Memoh generic ACP currently supplies HOME=/data, so the usual path is " +
      "/data/.cetas-memoh. Non-secret provider settings live in providers.json " +
      "as a direct object keyed by provider id. Credentials live under the " +
      "credentials directory in the canonical posoco-ext-credentials format. " +
      "Never ask the user to paste an API key or OAuth token into chat, never " +
      "read or display credential files through tools, and never copy secrets " +
      "into providers.json. Secret bootstrap belongs to the trusted host command " +
      "`cetas-memoh setup`. After the first model is available, use Memoh Tools " +
      "for allowed workspace/platform operations and for non-secret configuration " +
      "changes. Provider catalogs are assembled at process startup, so restart " +
      "the Cetas-Memoh runtime after changing provider settings. Memoh remains " +
      "the authority for conversation continuity, workspace/platform operations, " +
      "memory, and host authorization."
    ),
  )
  manuals
}
