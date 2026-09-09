///|
/// loop.mbt — the one-shot turn protocol.
///
/// Contract: every invocation runs exactly ONE user turn and
/// exits — there is no stdin loop. The task comes from `-- "<task>"` argv;
/// when absent, exactly one line is read from stdin (preserving
/// `echo "task" | cetas-headless` and pane send-text injection). EOF or an
/// empty task is a usage error (exit 2). A conversation continues by
/// re-invoking with `--session <id>`; absent `--session` mints a fresh
/// session, whose id the driver captures from the `session: <id>` stderr
/// line (text modes) or the `turn_started` event (`--jsonl`).
///
/// Output contract (2026-09-08, stdout purity): in text modes stdout carries
/// ONLY the answer — the default face prints the final answer as one block
/// (raw text, single trailing newline, empty answer prints nothing);
/// `--stream` prints text deltas as they arrive and closes with one trailing
/// newline (a model that never streams falls back to the answer block, so
/// stdout stays the answer). Everything else rides stderr: the
/// `session: <id>` line (always, written before the turn), the fixed
/// completion marker `[cetas-headless] turn 1 done` (always, also for
/// failed turns — waiting drivers never deadlock), the failure line
/// (`[cetas-headless] turn failed: <reason>`, no answer block on failure),
/// `--show-thinking` reasoning, and the `--verbose` event log. The
/// `--jsonl` face is unchanged: stdout is the pure event stream and the
/// session/marker ride the terminal events.
///
/// Live means live: every face rides an ordered queue with one background
/// pump task (ChunkDispatcher precedent) so each unit is written the moment
/// it completes — output is never batched to turn end. The queues close
/// inside the task group after the terminal writes, so the pump is fully
/// flushed (marker last on stderr) before the turn returns.
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
/// backlog here means the writer stalled; overflow drops the line (these
/// faces are display telemetry, and the committed events carry the content
/// anyway).
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
/// Write one terminal piece (answer tail, failure line, marker) either
/// through the face's live queue — preserving order with the units already
/// queued — or directly when that face has no queue.
async fn write_terminal(
  queue : @aqueue.Queue[String]?,
  text : String,
  write~ : async (String) -> Unit noraise,
) -> Unit noraise {
  match queue {
    Some(q) => ignore(q.try_put(text) catch { _ => false })
    None => write(text)
  }
}

///|
/// Run THE single turn and write its per-turn output. Returns `true` when
/// the turn failed, `false` when it completed. Faces:
///
/// - `jsonl` (the `--jsonl` face, unchanged): stdout is the pure event
///   stream; the session and marker ride the terminal events. When given,
///   `streamer`/`verbose` are ignored — `--jsonl` wins stdout.
/// - text modes: the `session: <id>` line goes to stderr before the turn;
///   stdout carries only the answer (one block, or deltas via `streamer`);
///   the marker and the failure line go to stderr; `verbose` receives the
///   jsonl-shaped event log on stderr.
pub async fn run_one_turn(
  agent~ : @posoco.Agent,
  session_id~ : String,
  task~ : String,
  jsonl~ : JsonlObserver?,
  streamer? : StreamPrinter? = None,
  verbose? : JsonlObserver? = None,
  write_out~ : async (String) -> Unit noraise,
  write_err? : async (String) -> Unit noraise = (_text : String) => (),
) -> Bool noraise {
  @async.with_task_group(async fn(group) {
    let queues : Array[@aqueue.Queue[String]] = []
    let mut out_queue : @aqueue.Queue[String]? = None
    let mut err_queue : @aqueue.Queue[String]? = None
    match jsonl {
      Some(observer) => {
        observer.begin_turn(turn_no=1, session_id~)
        let queue : @aqueue.Queue[String] = Queue(
          kind=Blocking(LIVE_QUEUE_CAPACITY),
        )
        observer.set_live_sink(fn(line : String) {
          ignore(queue.try_put(line + "\n") catch { _ => false })
        })
        out_queue = Some(queue)
        queues.push(queue)
        group.spawn_bg(async fn() { drain_live_queue(queue, write=write_out) })
      }
      None => {
        // Text modes: the session line is always the first output, on
        // stderr, before anything else runs.
        write_err("session: \{session_id}\n")
        // `--stream`: text deltas ride a live stdout queue so the answer
        // lands as it arrives.
        match streamer {
          Some(printer) =>
            if printer.stream {
              let queue : @aqueue.Queue[String] = Queue(
                kind=Blocking(LIVE_QUEUE_CAPACITY),
              )
              printer.set_text_sink(fn(token : String) {
                ignore(queue.try_put(token) catch { _ => false })
              })
              out_queue = Some(queue)
              queues.push(queue)
              group.spawn_bg(async fn() {
                drain_live_queue(queue, write=write_out)
              })
            }
          None => ()
        }
        // stderr faces — thinking deltas and the verbose event log share one
        // queue, so their push order is exactly the event order.
        let thinking_live = match streamer {
          Some(printer) => printer.stream && printer.show_thinking
          None => false
        }
        if thinking_live || verbose is Some(_) {
          let queue : @aqueue.Queue[String] = Queue(
            kind=Blocking(LIVE_QUEUE_CAPACITY),
          )
          if thinking_live {
            match streamer {
              Some(printer) =>
                printer.set_thinking_sink(fn(token : String) {
                  ignore(queue.try_put(token) catch { _ => false })
                })
              None => ()
            }
          }
          match verbose {
            Some(observer) => {
              observer.begin_turn(turn_no=1, session_id~)
              observer.set_live_sink(fn(line : String) {
                ignore(queue.try_put(line + "\n") catch { _ => false })
              })
            }
            None => ()
          }
          err_queue = Some(queue)
          queues.push(queue)
          group.spawn_bg(async fn() { drain_live_queue(queue, write=write_err) })
        } else {
          match verbose {
            Some(observer) => observer.begin_turn(turn_no=1, session_id~)
            None => ()
          }
        }
      }
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
            // `--show-thinking` without `--stream`: the final message's
            // committed reasoning block goes to stderr before the answer.
            match streamer {
              Some(printer) =>
                if printer.show_thinking && !printer.stream {
                  let block = text_block(printer.final_reasoning())
                  if block != "" {
                    write_terminal(err_queue, block, write=write_err)
                  }
                }
              None => ()
            }
            // stdout = the answer, nothing else. Streamed deltas close with
            // one trailing newline; a model that never streamed falls back
            // to the answer block so stdout stays the answer.
            match streamer {
              Some(printer) =>
                if printer.stream {
                  if printer.streamed_text() {
                    write_terminal(out_queue, "\n", write=write_out)
                  } else {
                    write_terminal(out_queue, text_block(text), write=write_out)
                  }
                } else {
                  write_out(text_block(text))
                }
              None => write_out(text_block(text))
            }
            match verbose {
              Some(observer) =>
                observer.emit_turn_completed(
                  summary=text,
                  marker=turn_marker(1),
                )
              None => ()
            }
            write_terminal(err_queue, turn_marker(1) + "\n", write=write_err)
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
            match verbose {
              Some(observer) =>
                observer.emit_turn_failed(
                  error=error.to_string(),
                  marker=turn_marker(1),
                )
              None => ()
            }
            // Failure: no answer block; the failure line and the marker keep
            // stderr's terminal-state contract.
            write_terminal(
              err_queue,
              "[cetas-headless] turn failed: \{single_line(error.to_string())}\n",
              write=write_err,
            )
            write_terminal(err_queue, turn_marker(1) + "\n", write=write_err)
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
