///|
/// loop.mbt — the one-shot turn protocol.
///
/// Contract: every invocation runs exactly ONE user turn and
/// exits — there is no stdin loop. The task comes from `-- "<task>"` argv;
/// when absent, exactly one line is read from stdin (preserving
/// `echo "task" | cetas-headless` and pane send-text injection). EOF or an
/// empty task is a usage error (exit 2). A conversation continues by
/// re-invoking with `--session <id>`; absent `--session` mints a fresh
/// session, whose id the driver captures from the `session: <id>` line
/// (human face) or the `turn_started` event (`--jsonl`).
///
/// Per turn stdout receives the session line, one human-readable summary
/// line, and a fixed completion marker line (`[cetas-headless] turn 1
/// done`) that drivers can grep — `herdr wait output --match`. The marker
/// is emitted for failed turns too: it marks the turn's terminal state, so
/// waiting drivers never deadlock on a failure.
///
/// Exit codes: 0 = the turn completed; 1 = the turn failed; 2 =
/// startup/usage errors.
///
/// Process visibility (2026-09-08): `--jsonl` (a `JsonlObserver` passed)
/// turns stdout into a pure event stream — turn_started / tool_call /
/// reasoning / tool_result / usage are projected live, and the runner folds
/// the summary and the marker into one terminal `turn_completed` /
/// `turn_failed` event. `--verbose` / `--stream` (a `TraceObserver` passed)
/// mirror the process onto stderr as a human trace. Live means live: every
/// observer rides an ordered queue with one background pump task
/// (ChunkDispatcher precedent) so each unit is written to its channel the
/// moment it completes — output is never batched to turn end. The queues
/// close inside the task group after the terminal event, so the pump is
/// fully flushed (marker last) before the turn returns.
///
/// Peer attribution: a task prefixed
/// `[cetas-peer from=<pane> session=<id>]` carries its task text wrapped in
/// a low-trust `herdr-peer` context envelope, so the model sees the
/// attribution without peer text posing as host authority. Plain tasks pass
/// through unchanged.
///
/// Interactive prompts never touch stdout: they ride the /dev/tty bypass,
/// or stderr when degraded. stdin stays pure task protocol.

///|
/// The fixed per-turn completion marker line (without the trailing newline).
pub fn turn_marker(turn_no : Int) -> String {
  "[cetas-headless] turn \{turn_no} done"
}

///|
/// Collapse a multi-line response into one protocol-safe line: every
/// whitespace run becomes a single space.
pub fn single_line(text : String) -> String {
  let builder = StringBuilder()
  let mut pending_space = false
  for ch in text {
    match ch {
      ' ' | '\t' | '\r' | '\n' => pending_space = true
      _ => {
        if pending_space {
          builder.write_char(' ')
          pending_space = false
        }
        builder.write_char(ch)
      }
    }
  }
  builder.to_string()
}

///|
/// Resolve THE single task: an explicit argv task wins and stdin is never
/// polled; otherwise exactly one line is read. The task is trimmed; `None`
/// means no task (EOF, empty line, or blank argv task) and the caller exits
/// 2 with a usage error.
pub async fn resolve_task(
  argv_task : String?,
  read_line~ : async () -> String? noraise,
) -> String? noraise {
  let raw = match argv_task {
    Some(task) => Some(task)
    None => read_line()
  }
  match raw {
    Some(task) => {
      let task = task.trim().to_owned()
      if task == "" {
        None
      } else {
        Some(task)
      }
    }
    None => None
  }
}

///|
/// Live queue capacity per output face. The pump drains continuously, so a
/// backlog here means the writer stalled; overflow drops the line (trace is
/// display telemetry, and the committed events carry the content anyway).
const LIVE_QUEUE_CAPACITY : Int = 4096

///|
/// The pump body: drain one live queue to its channel until the queue
/// closes. FIFO order is the queue's, which is push order — the emitted
/// sequence is exactly what a buffered drain would have printed, only
/// written per unit as units complete.
async fn drain_live_queue(
  queue : @aqueue.Queue[String],
  write~ : async (String) -> Unit noraise,
) -> Unit noraise {
  while true {
    let text : String = queue.get() catch {
      _ =>
        // Queue closed: the turn is ending.
        break
    }
    write(text)
  }
}

///|
/// Run THE single turn and write its per-turn output. Returns `true` when
/// the turn failed, `false` when it completed. In the human face the
/// `session: <id>` line is written first so drivers capture the id before
/// the summary; in the jsonl face the `turn_started` event already carries
/// the session and nothing extra is written. The optional trace observer
/// (`--verbose` / `--stream`) mirrors the process onto `write_err`.
pub async fn run_one_turn(
  agent~ : @posoco.Agent,
  session_id~ : String,
  task~ : String,
  jsonl~ : JsonlObserver?,
  trace? : TraceObserver? = None,
  write_out~ : async (String) -> Unit noraise,
  write_err? : async (String) -> Unit noraise = (_text : String) => (),
) -> Bool noraise {
  @async.with_task_group(async fn(group) {
    // Attach live sinks and spawn one pump per active face. The jsonl sink
    // terminates lines itself; the trace sink carries exact display pieces
    // (streaming deltas have no newline until their block closes).
    let queues : Array[@aqueue.Queue[String]] = []
    match jsonl {
      Some(observer) => {
        observer.begin_turn(turn_no=1, session_id~)
        let queue : @aqueue.Queue[String] = Queue(
          kind=Blocking(LIVE_QUEUE_CAPACITY),
        )
        observer.set_live_sink(fn(line : String) {
          ignore(queue.try_put(line + "\n") catch { _ => false })
        })
        group.spawn_bg(async fn() { drain_live_queue(queue, write=write_out) })
        queues.push(queue)
      }
      None => write_out("session: \{session_id}\n")
    }
    match trace {
      Some(observer) => {
        let queue : @aqueue.Queue[String] = Queue(
          kind=Blocking(LIVE_QUEUE_CAPACITY),
        )
        observer.set_live_sink(fn(text : String) {
          ignore(queue.try_put(text) catch { _ => false })
        })
        group.spawn_bg(async fn() { drain_live_queue(queue, write=write_err) })
        queues.push(queue)
      }
      None => ()
    }
    // Peer-attributed tasks ride the low-trust herdr-peer envelope; plain
    // tasks keep their exact text.
    let prompt = match parse_peer_envelope(task) {
      Some(peer) =>
        @devkit.context_envelope(
          ns="herdr-peer",
          kind="task",
          trust=false,
          source=peer.from,
          attrs=[("peer_session", peer.session)],
          content=peer.task,
        )
      None => task
    }
    let outcome : Result[String, @posoco.AgentError] = Ok(
      @cetas_core.run_prompt(agent, prompt, session_id),
    ) catch {
      error => Err(error)
    }
    let failed = match outcome {
      Ok(text) => {
        match jsonl {
          Some(observer) =>
            observer.emit_turn_completed(summary=text, marker=turn_marker(1))
          None => {
            write_out("[cetas-headless] turn 1: \{single_line(text)}\n")
            write_out(turn_marker(1) + "\n")
          }
        }
        false
      }
      Err(error) => {
        match jsonl {
          Some(observer) =>
            observer.emit_turn_failed(
              error=error.to_string(),
              marker=turn_marker(1),
            )
          None => {
            write_out(
              "[cetas-headless] turn 1 failed: \{single_line(error.to_string())}\n",
            )
            write_out(turn_marker(1) + "\n")
          }
        }
        true
      }
    }
    // Close inside the group: `with_task_group` returns only after every
    // child task has terminated, and the pump terminates only when the
    // queue closes — so the return means every line (marker included) has
    // been written.
    for queue in queues {
      queue.close()
    }
    failed
  }) catch {
    // The group body is raise-free by construction (run_prompt's raise is
    // captured above; writers are noraise); this is the safety net.
    _ => true
  }
}
