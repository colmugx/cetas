///|
/// Routing note appended to the system prompt. Configuration is forme's
/// primary goal, so cetas-config leads; the manuals are inline skills
/// registered under the host's skills extension, and activate_skill is the
/// disclosure path.
pub impl @posoco.SystemPromptContributor for Forme with fn system_prompt(
  _self : Forme,
) -> String {
  "Call activate_skill for the matching built-in manual first: cetas-config for setup/configuration, cetas-usage for usage, cetas-about for identity; answer from it, not memory."
}

///|
pub extend Forme with @posoco.SystemPromptContributor::{system_prompt}
