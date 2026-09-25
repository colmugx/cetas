///|
/// Routing note appended to the system prompt: capability/usage/config
/// questions must go through the built-in manuals, not the model's memory of
/// them. The manuals are inline skills registered under the host's skills
/// extension, so activate_skill is the disclosure path.
pub impl @posoco.SystemPromptContributor for Forme with fn system_prompt(
  _self : Forme,
) -> String {
  "For Cetas identity/capability/usage/config questions, call activate_skill for the matching built-in manual first: cetas-about, cetas-usage, or cetas-config; answer from it."
}

///|
pub extend Forme with @posoco.SystemPromptContributor::{system_prompt}
