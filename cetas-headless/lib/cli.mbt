///|
/// cli.mbt — the decided command surface (cetas-headless-design §二):
///
///   cetas-headless [--model <id>] [--effort <level>] [--session <id>]
///                  [--goal <condition>]
///                  [--yolo | --permission <readonly|workspace_write|interactive>]
///                  [--jsonl] [-- "<task>"]
///
/// One invocation = one user turn: `--yolo` and `--permission` are mutually
/// exclusive; `--` ends the flags — every argv after it is THE task (when
/// absent, one line is read on stdin). Parsing is pure so the flag table and
/// rejection rules stay unit-testable.

///|
/// Parsed invocation. Zero values ("") mean "not given".
pub(all) struct HeadlessCli {
  /// Run-scoped model override (`provider/model` slot id); never persisted.
  model : String
  /// Run-scoped reasoning effort override; never persisted.
  effort : String
  /// Existing session id to resume; "" mints a fresh session id.
  session_id : String
  /// Goal condition for the goal runner ("" = no goal ext).
  goal : String
  /// Unattended master switch: Yolo mode AND no terminal UI.
  yolo : Bool
  /// Structured face: stdout carries the pure JSONL event stream instead of
  /// the human summary + marker lines; prompts stay on stderr/tty regardless.
  jsonl : Bool
  /// Explicit permission mode; None falls back to the default posture.
  permission_mode : @permission.PermissionMode?
  /// THE task (argv after `--`, joined with spaces); "" = read one line
  /// from stdin instead.
  task : String
}

///|
/// Parse a `--permission` value. Yolo is intentionally unreachable here —
/// unattended runs are expressed with `--yolo` only.
pub fn parse_permission_mode_str(raw : String) -> @permission.PermissionMode? {
  match raw {
    "readonly" => Some(@permission.ReadOnly)
    "workspace_write" => Some(@permission.WorkspaceWrite)
    "interactive" => Some(@permission.Interactive)
    _ => None
  }
}

///|
pub fn parse_headless_cli(argv : Array[String]) -> Result[HeadlessCli, String] {
  let mut model = ""
  let mut effort = ""
  let mut session_id = ""
  let mut goal = ""
  let mut yolo = false
  let mut jsonl = false
  let mut permission_mode : @permission.PermissionMode? = None
  let mut task = ""
  let mut i = 0
  let mut after_task_marker = false
  while i < argv.length() {
    let arg = argv[i]
    if after_task_marker {
      task = if task == "" { arg } else { task + " " + arg }
    } else if arg == "--" {
      after_task_marker = true
    } else if arg == "--model" {
      i += 1
      if i >= argv.length() {
        return Err("--model requires a value (<provider/model>)")
      }
      model = argv[i]
    } else if arg == "--effort" {
      i += 1
      if i >= argv.length() {
        return Err("--effort requires a value (<low|medium|high|...>)")
      }
      effort = argv[i]
    } else if arg == "--session" {
      i += 1
      if i >= argv.length() {
        return Err("--session requires a value (<session id>)")
      }
      session_id = argv[i]
    } else if arg == "--goal" {
      i += 1
      if i >= argv.length() {
        return Err("--goal requires a value (<goal condition>)")
      }
      goal = argv[i]
    } else if arg == "--yolo" {
      yolo = true
    } else if arg == "--jsonl" {
      jsonl = true
    } else if arg == "--permission" {
      i += 1
      if i >= argv.length() {
        return Err(
          "--permission requires a value: readonly|workspace_write|interactive",
        )
      }
      match parse_permission_mode_str(argv[i]) {
        Some(mode) => permission_mode = Some(mode)
        None =>
          return Err(
            "unknown permission mode '\{argv[i]}': expected readonly|workspace_write|interactive",
          )
      }
    } else if arg.has_prefix("--") {
      return Err("unknown flag: \{arg}")
    } else {
      return Err(
        "unexpected argument '\{arg}' — use -- to pass the initial task",
      )
    }
    i += 1
  }
  if yolo && permission_mode is Some(_) {
    return Err("--yolo and --permission are mutually exclusive")
  }
  Ok({ model, effort, session_id, goal, yolo, jsonl, permission_mode, task, })
}

///|
/// The startup posture: an explicit `--permission` wins; `--yolo` is Yolo;
/// the default is the interactive WorkspaceWrite + terminal approval shape.
pub fn resolve_permission_mode(cli : HeadlessCli) -> @permission.PermissionMode {
  match cli.permission_mode {
    Some(mode) => mode
    None => if cli.yolo { @permission.Yolo } else { @permission.WorkspaceWrite }
  }
}

///|
/// Whether the terminal UI surface (approval bypass, ask_question) is wired.
/// `--yolo` is the unattended master switch: no UI, approvals never asked.
pub fn wants_terminal_ui(cli : HeadlessCli) -> Bool {
  !cli.yolo
}
