///|
/// Routing note appended to the system prompt: capability/usage/config
/// questions must go through the built-in manuals, not the model's memory of
/// them. The manuals are inline skills registered under the host's skills
/// extension, so activate_skill is the disclosure path.
pub impl @posoco.SystemPromptContributor for Forme with fn system_prompt(
  _self : Forme,
) -> String {
  "When the user asks what cetas is, what it can do, how to use a feature, or how cetas is configured, call activate_skill on the matching built-in manual (cetas-about, cetas-usage, cetas-config) first and answer from its instructions rather than from memory."
}
