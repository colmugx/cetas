///|
/// cetas-headless — run exactly ONE cetas user turn per invocation.
///
/// The task comes from `-- "<task>"` argv, or — when absent — from exactly
/// one line read on stdin (EOF or an empty task is a usage error). Absent
/// `--session <id>` mints a fresh session; the id is printed as a
/// `session: <id>` line before the turn's summary (or carried by the
/// `turn_started` event under `--jsonl`) so drivers can continue the
/// conversation by re-invoking with `--session`. Approval prompts and
/// interactive UI requests bypass stdin via /dev/tty; degraded (no tty) they
/// deny with a hint on stderr. `--yolo` is the unattended master switch.
/// `CETAS_HOME` overrides the cetas home directory (default `HOME`). A model
/// provider must be configured — startup fails loudly with exit code 2.
/// Exit codes: 0 the turn completed; 1 the turn failed; 2 startup/usage.

///|
/// Startup failure exit: bad CLI or composition failure. Native-only; the
/// async runtime's own exit is not public, so call libc directly.
extern "C" fn exit(code : Int) = "exit"

///|
const USAGE : String = "usage: cetas-headless [--model <id>] [--effort <level>] [--session <id>] [--yolo | --permission <readonly|workspace_write|interactive>] [--jsonl] [-- \"<task>\"]\n"

///|
async fn main {
  let args = @env.args()
  let argv : Array[String] = []
  for i = 1; i < args.length(); i = i + 1 {
    argv.push(args[i])
  }
  let cli = match @lib.parse_headless_cli(argv) {
    Ok(cli) => cli
    Err(message) => {
      @stdio.stderr.write("cetas-headless: \{message}\n")
      @stdio.stderr.write(USAGE)
      exit(2)
      abort("cetas-headless: unreachable after exit")
    }
  }
  let home = match @env.get_env_var("CETAS_HOME") {
    Some(value) if value != "" => value
    _ =>
      match @env.get_env_var("HOME") {
        Some(value) => value
        None => "."
      }
  }
  let cwd = match @env.current_dir() {
    Some(dir) => dir
    None => "."
  }
  let stderr_note = async fn(text : String) noraise {
    @stdio.stderr.write(text) catch {
      _ => ()
    }
  }
  // The terminal bypass: one channel shared by approval prompts and UI
  // requests. Absent under --yolo, or when no controlling terminal exists —
  // then the approval source degrades to deny-with-hint on stderr and the
  // UI port is simply not attached (ask_question falls back on its own).
  let tty : @lib.TtyChannel? = if @lib.wants_terminal_ui(cli) {
    @lib.open_tty_channel()
  } else {
    None
  }
  if tty is None && @lib.wants_terminal_ui(cli) {
    stderr_note(
      "cetas-headless: no controlling terminal — approvals deny automatically (unattended, use --yolo)\n",
    )
  }
  let approval : &@permission.ApprovalSource? = if @lib.wants_terminal_ui(cli) {
    Some(
      @lib.TerminalApprovalSource::TerminalApprovalSource(
        tty~,
        notice=stderr_note,
      )
      as &@permission.ApprovalSource,
    )
  } else {
    None
  }
  let ui : &@posoco.UiPort? = match tty {
    Some(tty) =>
      Some(
        @lib.TerminalUiPort::TerminalUiPort(tty=Some(tty)) as &@posoco.UiPort,
      )
    None => None
  }
  // THE task: an argv task wins; otherwise exactly one line is read on
  // stdin (pane send-text injection, `echo "task" | cetas-headless`). EOF
  // or an empty task is a usage error — there is no line loop to wait in.
  let argv_task : String? = if cli.task == "" { None } else { Some(cli.task) }
  let read_line = async fn() noraise {
    @stdio.stdin.read_until("\n") catch {
      _ => None
    }
  }
  let task = match @lib.resolve_task(argv_task, read_line~) {
    Some(task) => task
    None => {
      @stdio.stderr.write(
        "cetas-headless: no task given — pass -- \"<task>\" or pipe one line on stdin\n",
      )
      @stdio.stderr.write(USAGE)
      exit(2)
      abort("cetas-headless: unreachable after exit")
    }
  }
  let write_out = async fn(text : String) noraise {
    @stdio.stdout.write(text) catch {
      _ => ()
    }
  }
  // The `--jsonl` structured face: the observer rides the composition as a
  // tail extension and buffers event lines; the single-turn runner drains
  // them to stdout after the turn. Without `--jsonl` nothing changes.
  let observer : @lib.JsonlObserver? = if cli.jsonl {
    Some(@lib.JsonlObserver::JsonlObserver())
  } else {
    None
  }
  let tail_exts : Array[&@posoco.Extension] = match observer {
    Some(obs) => [obs as &@posoco.Extension]
    None => []
  }
  // The whole lifecycle runs inside one task group (the group's parameter
  // is pinned to Unit — the MCP runtime rides it): compose, announce the
  // session, run the single turn, shut down, exit by outcome.
  let failed : Array[Bool] = [false]
  @async.with_task_group(group => {
    let host = @lib.CetasHeadlessHost(
      home~,
      cwd~,
      mode=@lib.resolve_permission_mode(cli),
      approval~,
      ui~,
      model_override=cli.model,
      effort_override=cli.effort,
      session_id=cli.session_id,
      mcp_group=Some(group),
      tail_exts~,
    ) catch {
      error => {
        @stdio.stderr.write(
          "cetas-headless: agent composition failed: \{error.to_string()}\n",
        )
        exit(2)
        abort("cetas-headless: unreachable after exit")
      }
    }
    failed[0] = @lib.run_one_turn(
      agent=host.agent,
      session_id=host.session_id,
      task~,
      jsonl=observer,
      write_out~,
    )
    host.agent.shutdown()
  })
  // Exit codes: 0 the turn completed, 1 the turn failed; startup/usage
  // failures above keep exit 2.
  if failed[0] {
    exit(1)
  }
}
