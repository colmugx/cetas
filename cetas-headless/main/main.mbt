///|
/// cetas-headless — run exactly ONE cetas user turn per invocation.
///
/// The task comes from `-- "<task>"` argv, or — when absent — from exactly
/// one line read on stdin (EOF or an empty task is a usage error). Absent
/// `--session <id>` mints a fresh session; the id is printed as a
/// `session: <id>` line on STDERR before the turn (or carried by the
/// `turn_started` event under `--jsonl`) so drivers can continue the
/// conversation by re-invoking with `--session`. stdout purity
/// (2026-09-08): in text modes stdout carries ONLY the answer — one block
/// by default, text deltas under `--stream`; the marker line
/// (`[cetas-headless] turn 1 done`, also for failed turns), the failure
/// line, warnings, and approval/tty prompts all ride stderr.
/// `--verbose` routes the jsonl-shaped process event log to stderr;
/// `--show-thinking` routes reasoning to stderr. Approval prompts and
/// interactive UI requests bypass stdin via /dev/tty; degraded (no tty) they
/// deny with a hint on stderr. `--yolo` is the unattended master switch.
/// `CETAS_HOME` overrides the cetas home directory (default: platform home —
/// `USERPROFILE` on Windows, `HOME` elsewhere). A model
/// provider must be configured — startup fails loudly with exit code 2.
/// So does a `--model` that names no configured slot (the message lists the
/// valid `provider/model` slot ids) or an `--effort` the active slot
/// rejects (the message lists that slot's supported efforts): a one-shot
/// run must never silently fall back to the settings.json selection.
/// Exit codes: 0 the turn completed; 1 the turn failed; 2 startup/usage.

///|
/// Startup failure exit: bad CLI or composition failure. Native-only; the
/// async runtime's own exit is not public, so call libc directly.
extern "C" fn exit(code : Int) = "exit"

///|
const USAGE : String = "usage: cetas-headless [--model <id>] [--effort <level>] [--session <id>] [--yolo | --permission <readonly|workspace_write|interactive>] [--stream] [--verbose] [--show-thinking] [--jsonl] [-- \"<task>\"]\n"

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
  let home = @cetas_core.cetas_home()
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
  let write_err = async fn(text : String) noraise {
    @stdio.stderr.write(text) catch {
      _ => ()
    }
  }
  // Output faces. `--jsonl` keeps its frozen stdout contract and wins
  // stdout over the text faces. Text modes get a StreamPrinter (answer
  // deltas / thinking routing via tail_exts) and — for `--verbose` — a
  // second JsonlObserver whose frozen event log is pumped to stderr while
  // stdout stays answer-only. The single-turn runner wires each face to a
  // live pump so every unit is written the moment it completes.
  let observer : @lib.JsonlObserver? = if cli.jsonl {
    Some(@lib.JsonlObserver::JsonlObserver(stream=cli.stream))
  } else {
    None
  }
  let streamer : @lib.StreamPrinter? = if cli.jsonl {
    None
  } else {
    Some(
      @lib.StreamPrinter::StreamPrinter(
        stream=cli.stream,
        show_thinking=cli.show_thinking,
      ),
    )
  }
  let verbose : @lib.JsonlObserver? = if cli.verbose && !cli.jsonl {
    Some(@lib.JsonlObserver::JsonlObserver(id="cetas_headless_verbose"))
  } else {
    None
  }
  let tail_exts : Array[&@posoco.Extension] = []
  match observer {
    Some(obs) => tail_exts.push(obs as &@posoco.Extension)
    None => ()
  }
  match streamer {
    Some(printer) => tail_exts.push(printer as &@posoco.Extension)
    None => ()
  }
  match verbose {
    Some(log) => tail_exts.push(log as &@posoco.Extension)
    None => ()
  }
  // Compose, announce the session, run the single turn, shut down, exit by
  // outcome.
  let host = @lib.CetasHeadlessHost(
    home~,
    cwd~,
    mode=@lib.resolve_permission_mode(cli),
    approval~,
    ui~,
    model_override=cli.model,
    effort_override=cli.effort,
    session_id=cli.session_id,
    tail_exts~,
    // Every remaining composition warn reaches stderr — nothing degrades
    // silently in a one-shot run.
    warn=write_err,
  ) catch {
    @posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~) if manifest_id.has_suffix(
        ".model_override",
      ) => {
      @stdio.stderr.write("cetas-headless: \{detail}\n")
      exit(2)
      abort("cetas-headless: unreachable after exit")
    }
    error => {
      @stdio.stderr.write(
        "cetas-headless: agent composition failed: \{error.to_string()}\n",
      )
      exit(2)
      abort("cetas-headless: unreachable after exit")
    }
  }
  let failed = @lib.run_one_turn(
    agent=host.agent,
    session_id=host.session_id,
    task~,
    jsonl=observer,
    streamer~,
    verbose~,
    write_out~,
    write_err~,
  )
  host.agent.shutdown()
  // Exit codes: 0 the turn completed, 1 the turn failed; startup/usage
  // failures above keep exit 2.
  if failed {
    exit(1)
  }
}
