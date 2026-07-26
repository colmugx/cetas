///|
/// Minimal product-owned base prompt.
///
/// Cetas defines only its identity, active workspace, and execution policy as
/// a single base string. Capability-specific instructions come from extension
/// contributors via `SystemPromptContributor::system_prompt`, appended in
/// registration order by `SystemPromptHook::new`.
fn cetas_base_system_prompt(
  cwd : String,
) -> String raise @posoco.CompositionError {
  if cwd.trim().is_empty() {
    raise @posoco.CompositionError::InvalidSystemPrompt(
      "cetas cwd must not be empty",
    )
  }
  let parts : Array[String] = [
    "You are Cetas, a coding agent. Complete the user's coding task in the active workspace.",
    "Working directory: \{cwd}",
    "Inspect relevant code before changing it. Follow applicable project instructions. Make targeted changes that fix root causes. Run focused checks after editing. Surface tool and verification failures exactly; never claim work that was not verified. Ask for user input only when the missing decision materially changes the result.",
  ]
  parts.join("\n\n")
}
