///|
/// cetas-config manual: the flagship. Helping the user set cetas up and
/// configure it — especially ~/.cetas/settings.json — is forme's primary
/// goal, so this manual leads the catalog ordering and the routing note.
fn cetas_config_manual() -> String {
  let manual =
    #|# Configuring Cetas
    #|
    #|Helping the user set cetas up and configure it is the primary job of
    #|this manual. Prefer making the change with your tools over telling the
    #|user to hand-edit; validate before writing and report exactly what
    #|changed afterwards.
    #|
    #|## The cetas home directory
    #|All durable state lives under ~/.cetas by default:
    #|- settings.json — provider, model, and feature configuration
    #|- credentials/ — login credentials written by /login (a separate
    #|  store; never hand-edit these files)
    #|- sessions/ — journaled conversations, one bucket per project
    #|- profiles — saved model selections
    #|- agent/AGENTS.md — global personal instructions
    #|Set the CETAS_HOME environment variable to move the whole directory;
    #|the fallback is the platform home — USERPROFILE on Windows, HOME
    #|elsewhere.
    #|
    #|## settings.json
    #|The file is a JSON object. Top-level keys:
    #|- "providers" — one entry per provider with its model list
    #|- "model" — the active conversation model as "provider/model"
    #|- "reasoning_effort" — the active effort level (falls back to the
    #|  slot's advertised default when absent)
    #|- "decision_model" — the active decision model slot, independent of
    #|  "model"; the two selections never cross kinds
    #|The app rewrites this file itself (model switches, logins, feature
    #|toggles) while preserving every unrelated key, and writes are atomic.
    #|Model entries may declare metadata such as context_window (capacity
    #|in tokens), image-input capability, and prompt_profile; these are
    #|read and validated from settings — write only values you have
    #|verified for that provider, never guessed ones.
    #|
    #|## What takes effect when
    #|The system prompt is assembled once per session and frozen
    #|afterwards; configuration changes that affect it take effect in the
    #|next session. Persistent personal preferences (tone, formatting
    #|habits) are better expressed as memory or project instructions
    #|(AGENTS.md) than as configuration.
  manual
}

///|
/// cetas-usage manual: how to drive cetas day to day.
fn cetas_usage_manual() -> String {
  let manual =
    #|# Using Cetas
    #|
    #|## Turns
    #|A turn is one user message plus everything the agent does to answer
    #|it: the model may call tools (read, write, edit, glob, grep, shell)
    #|in sequence or parallel waves; risky calls pause for approval
    #|depending on the permission mode; the turn ends with the assistant's
    #|final text. Long shell commands can run in the background (check,
    #|wait on, or kill them with bash_status, bash_wait, bash_kill) instead
    #|of blocking the turn, and every shell command is stopped at a hard
    #|deadline (5 minutes by default).
    #|
    #|## Commands
    #|Type / to browse the live list; the exact set depends on the host and
    #|the installed extensions. Common ones:
    #|- /new — start a fresh session
    #|- /sessions — browse and resume past sessions
    #|- /resume — resume this session's interrupted turn
    #|- /rewind — rewind this session to an earlier message
    #|- /model — pick a model and effort level
    #|- /login — authenticate a provider (API key or browser login)
    #|- /compact — compact the conversation context
    #|- /skills — browse discovered agent skills ($name activates one)
    #|- /permission — show or switch the permission mode (works mid-turn)
    #|- /questions, /answer — review and answer pending questions
    #|- /goal — run one persistent objective across bounded turns
    #|- /workflow, /board — planned multi-task workflows and their board
    #|- /status, /quota — session/model status and remaining quota
    #|- /help — quick self-description
    #|
    #|## Permission modes
    #|- readonly — file writes and shell commands are denied
    #|- workspace_write — writes inside the workspace are allowed, others ask
    #|- interactive — ask before every consequential action
    #|- yolo — no approval prompts (use with care); the default posture for
    #|  the interactive hosts (terminal and ACP), headless keeps workspace_write
    #|Switch with /permission <mode>; it works mid-turn.
    #|
    #|## Input conveniences (cetas-js)
    #|- @path attaches a workspace file to the message (Tab/Enter completes
    #|  it); image files reach vision-capable models as real image parts
    #|- ESC interrupts the running turn (first press denies a pending
    #|  approval); double-ESC while idle opens /rewind
    #|- Typing while a turn runs stays live; Enter queues it as a follow-up
    #|- ctrl+t toggles thinking blocks; ctrl+o toggles tool output
    #|- If the agent asks a question, just type the reply, or use /questions
    #|  to pick a pending one
    #|
    #|## Sessions
    #|Every session is journaled under the cetas home directory. /sessions
    #|lists and resumes them; /new starts over without deleting history.
  manual
}

///|
/// cetas-about manual: what cetas is and what it can do. `version_note`
/// (host-provided, e.g. "0.10.9 (npm)") is interpolated as the running
/// version; without it the manual tells the model to say the version is
/// unknown rather than guessing.
fn cetas_about_manual(version_note~ : String? = None) -> String {
  let head =
    #|# About Cetas
    #|
    #|Cetas is a coding agent that runs on your machine. You talk to it in
    #|natural language; it reads and edits files, searches the workspace,
    #|runs shell commands, and explains what it did.
    #|
    #|## What cetas can do
    #|- Answer questions about a codebase by reading and searching files
    #|- Implement features and fix bugs across multiple files (read, edit,
    #|  verify)
    #|- Run shell commands, tests, and builds, then react to the output;
    #|  long commands can run in the background
    #|- Use installed agent skills: progressively loaded how-to instructions
    #|- Delegate independent subtasks to subagents, including in the
    #|  background
    #|- Run persistent goals and planned multi-task workflows (/goal,
    #|  /workflow, /board)
    #|- Connect MCP tool servers; attach workspace images to messages
    #|- Keep sessions: every turn is journaled and can be resumed or rewound
    #|- Optionally persist memory across sessions (nowledge-mem, when
    #|  enabled)
    #|
    #|## What cetas will not do
    #|- Touch files outside the workspace without explicit user action
    #|- Skip approval steps required by the current permission mode
    #|- Invent tool results: every factual claim comes from an actual tool
    #|  call
    #|
    #|## Hosts
    #|- cetas-js — interactive terminal UI (approvals, model picker,
    #|  commands). Ships two ways: as the npm package @posoco/cetas, or as
    #|  a standalone compiled binary.
    #|- cetas-acp — editor integration over the ACP protocol (JSON-RPC,
    #|  stdio)
    #|- cetas-run — runs exactly one user turn per invocation; the driver
    #|  for delegated subagent runs
    #|
    #|Any other cetas-* directory or host is proof-of-concept code, not
    #|product: never describe or recommend it.
  let version = match version_note {
    Some(note) =>
      "\nRunning version: \{note}. State this version when asked; it is the only version you know.\n"
    None =>
      "\nNo version line is configured for this host: if asked for the running version, say you cannot determine it — never guess.\n"
  }
  let tail =
    #|
    #|## Answering identity questions
    #|For identity/capability introductions, summarize this manual and
    #|offer a concrete example task instead of listing every tool. Keep
    #|project inspection small: one directory listing plus at most two
    #|manifest/README-level reads, never source files; mention what the
    #|project appears to be. If `## Memory` exists, summarize it briefly.
    #|
    #|Reply in the user's language. For a Chinese self-introduction, open
    #|exactly with "真拿你没办法，坐好喽". Never use or translate that phrase
    #|for other languages.
  head + version + tail
}
