///|
/// cetas-about manual: what cetas is and what it can do.
fn cetas_about_manual() -> String {
  let manual =
    #|# About Cetas
    #|
    #|Cetas is a coding agent that runs in your terminal (cetas-js) or inside
    #|your editor (cetas-acp). You talk to it in natural language; it reads and
    #|edits files, searches the workspace, runs shell commands, and explains
    #|what it did.
    #|
    #|## What cetas can do
    #|- Answer questions about a codebase by reading and searching files
    #|- Implement features and fix bugs across multiple files (read, edit, verify)
    #|- Run shell commands, tests, and builds, then react to the output
    #|- Use installed agent skills: progressively loaded how-to instructions
    #|- Keep sessions: every turn is journaled and can be resumed later
    #|- Optionally persist memory across sessions (nowledge-mem, when enabled)
    #|
    #|## What cetas will not do
    #|- Touch files outside the workspace without explicit user action
    #|- Skip approval steps required by the current permission mode
    #|- Invent tool results: every factual claim comes from an actual tool call
    #|
    #|## Hosts
    #|- cetas-js — interactive terminal UI (approvals, model picker, commands)
    #|- cetas-acp — editor integration over the ACP protocol (JSON-RPC, stdio)
    #|
    #|When the user asks "what can you do", summarize this manual, then offer a
    #|concrete example task instead of listing every tool.
  manual
}

///|
/// cetas-usage manual: how to drive cetas day to day.
fn cetas_usage_manual() -> String {
  let manual =
    #|# Using Cetas
    #|
    #|## Turns
    #|A turn is one user message plus everything the agent does to answer it:
    #|the model may call tools (read, write, edit, glob, grep, shell) in
    #|sequence or parallel waves; risky calls pause for approval depending on
    #|the permission mode; the turn ends with the assistant's final text.
    #|
    #|## Commands
    #|Type / to browse the live list; the exact set depends on the host and the
    #|installed extensions. Common ones:
    #|- /new — start a fresh session
    #|- /sessions — browse and resume past sessions
    #|- /model — pick a model and effort level
    #|- /skills — browse discovered agent skills ($name activates one)
    #|- /login — authenticate a provider (API key or OAuth)
    #|- /profile — save, load, or delete named configuration profiles
    #|- /compact — compact the conversation context
    #|- /help — quick self-description
    #|
    #|## Input conveniences (cetas-js)
    #|- @path attaches a workspace file to the message (Tab completes the path)
    #|- ESC interrupts the running turn (first press denies a pending approval)
    #|- Typing while a turn runs queues the text as a follow-up message
    #|
    #|## Permission modes
    #|- readonly — file writes and shell commands are denied
    #|- workspace_write — writes inside the workspace are allowed, others ask
    #|- interactive — ask before every consequential action
    #|- yolo — no approval prompts (use with care)
    #|Switch with /permission <mode>; it works mid-turn.
    #|
    #|## Sessions
    #|Every session is journaled under the cetas home directory. /sessions
    #|lists and resumes them; /new starts over without deleting history.
  manual
}

///|
/// cetas-config manual: where cetas keeps state and how to configure it.
fn cetas_config_manual() -> String {
  let manual =
    #|# Configuring Cetas
    #|
    #|## The cetas home directory
    #|All state lives under ~/.cetas by default:
    #|- settings.json — provider configuration
    #|- sessions/ — journaled conversations
    #|- profile files — saved configuration profiles
    #|Set the CETAS_HOME environment variable to move the whole directory;
    #|HOME is the fallback when it is unset.
    #|
    #|## Providers and models
    #|settings.json holds a providers object with one entry per provider and
    #|its model list. /login writes credentials after an interactive login.
    #|The active model selection persists across restarts; switch it with
    #|/model.
    #|
    #|## Profiles
    #|/profile save <name> snapshots the current configuration,
    #|/profile load <name> restores it, /profile delete <name> removes it.
    #|
    #|## What is not configurable at runtime
    #|The system prompt is assembled once per session and frozen afterwards;
    #|configuration changes that affect it take effect in the next session.
    #|Persistent personal preferences (tone, formatting habits) are better
    #|expressed as memory or project instructions (AGENTS.md) than as
    #|configuration.
  manual
}
