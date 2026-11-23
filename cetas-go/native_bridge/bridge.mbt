///|
/// Go and MoonBit exchange owned copies of UTF-8 frames via C queues.
#borrow(data)
extern "C" fn publish(data : Bytes, length : Int32) -> Int32 = "cetas_bridge_publish"

///|
extern "C" fn next_command() -> Int32 = "cetas_bridge_next_command"

///|
/// Copies one queued UTF-8 JSON request into MoonBit-owned bytes.
#borrow(dst)
extern "C" fn next_harness(dst : Bytes, capacity : Int32) -> Int32 = "cetas_bridge_next_harness"

///|
/// Read end of the command/request readiness pipe. The Go host writes one byte
/// after it queues work; the queue stays authoritative and the byte only means
/// "there may be work". Ownership of the descriptor transfers to this
/// scheduler, its single reader, and it is closed when this loop shuts down. The
/// host keeps the write end for the process lifetime, so a late write can
/// neither block nor raise SIGPIPE. Returns -1 when the channel is unusable; the
/// stage below says why. On Windows the command loop polls instead.
#cfg(not(platform="windows"))
extern "C" fn command_wake_fd() -> Int32 = "cetas_bridge_command_fd"

///|
/// POSIX descriptor handoff: the C side yields an int, while the async runtime
/// owns descriptors as the opaque `@types.Fd` with an int ABI.
#cfg(not(platform="windows"))
fn fd_from_raw(raw : Int32) -> @types.Fd = "%identity"

///|
/// Exact step that failed while building the notify channel (0 = healthy,
/// 1 = `pipe()`, 2 = `fcntl()` non-blocking/cloexec, 3 = the dup write guard,
/// 4 = disabled by a transport test).
extern "C" fn command_wake_stage() -> Int32 = "cetas_bridge_command_wake_stage"

///|
/// The errno behind `command_wake_stage`; 0 when none applies. POSIX only.
#cfg(not(platform="windows"))
extern "C" fn command_wake_errno() -> Int32 = "cetas_bridge_command_wake_errno"

///|
/// Human name for one notify-channel failure stage; an unknown stage says so
/// rather than guessing a cause.
fn wake_stage_text(stage : Int32) -> String {
  match stage {
    0 => "no failure recorded"
    1 => "pipe() failed"
    2 => "fcntl() failed setting non-blocking/cloexec"
    3 => "fcntl(F_DUPFD_CLOEXEC) failed for the producer-write guard"
    4 => "notification channel disabled by a transport test"
    5 => "CreateEventW() failed"
    _ => "unknown failure stage \{stage}"
  }
}

///|
/// Adopt the command-channel readiness signal into the async scheduler. POSIX
/// hands over a descriptor, and `RawFd` takes ownership even when adoption fails
/// (it closes the descriptor itself), so neither branch can leak it.
#cfg(not(platform="windows"))
async fn adopt_command_wake() -> Result[@raw_fd.RawFd, String] {
  let fd = command_wake_fd()
  if fd < 0 {
    return Err(
      "\{wake_stage_text(command_wake_stage())} (errno=\{command_wake_errno()})",
    )
  }
  let raw = @raw_fd.RawFd(fd_from_raw(fd)) catch {
    error =>
      return Err(
        "descriptor could not be adopted by the async scheduler: \{error}",
      )
  }
  Ok(raw)
}

///|
/// Windows polls every 10 ms. The empty error is the normal polling path;
/// a notification setup failure still reports its stage.
#cfg(platform="windows")
fn adopt_command_wake() -> Result[@raw_fd.RawFd, String] {
  let stage = command_wake_stage()
  if stage != 0 {
    return Err(wake_stage_text(stage))
  }
  Err("")
}

///|
/// The notify channel is an optimization, never a requirement: without it the
/// host still serves commands through bounded polling. The degradation is
/// reported exactly once as an explicit `infra.error` frame and the failed
/// descriptor is closed rather than retried every iteration — never swallowed,
/// and never claiming the wait is still healthy.
fn emit_degraded(detail : String) -> Unit {
  emit(
    Json::object({
      "type": Json::string("infra.error"),
      "degraded": Json::string("command_poll_10ms"),
      "detail": Json::string("\{detail}; falling back to 10 ms command polling"),
    }).stringify(),
  )
}

///|
/// A rejected publish is not swallowed here on purpose: C counts each rejection
/// under its exact cause and the Go pump turns any new one into a fatal, named
/// diagnostic. Writing to stderr would corrupt the terminal the TUI owns, so the
/// counter stays the single channel.
fn emit(frame : String) -> Unit {
  let data = @utf8.encode(frame)
  ignore(publish(data, data.length()))
}

///|
/// Startup progress for the terminal: one frame per composition phase, so the
/// first-paint status line reflects work instead of a static "connecting".
fn emit_boot_progress(phase : String, ms : Int64) -> Unit {
  emit(
    Json::object({
      "type": Json::string("infra.boot.progress"),
      "phase": Json::string(phase),
      "ms": Json::number(ms.to_double()),
    }).stringify(),
  )
}

///|
/// Reply to a harness request that arrived while the runtime was still composing,
/// preserving its correlation id: a named refusal, never a dropped request the
/// host would wait on.
fn reject_while_composing(raw : String) -> Unit {
  let request : Json = @json.parse(raw) catch { _ => Json::null() }
  let id = if request is Json::Object(fields) &&
    fields.get("id") is Some(Json::Number(number, ..)) {
    number.to_int()
  } else {
    -1
  }
  emit(harness_reply(id, harness_error("runtime is still composing")))
}

///|
fn emit_snapshot(
  frame_type : String,
  snapshot : Json,
  boot~ : Bool = false,
) -> Unit {
  let buf = StringBuilder()
  buf <+
    $|{"type":"\{frame_type}",
  if boot {
    buf <+
      $|"status":"ready","boot_state":"ready",
  }
  buf <+
    $|"snapshot":\{snapshot.stringify()}}
  emit(buf.to_string())
}

///|
/// Run a single-owner async domain on a locked Go worker OS thread.
/// Real ConsoleRuntime construction is attempted, never fabricated.
#export_name("cetas_infra_run")
pub fn run_infra() -> Int32 {
  let result = Ref(0)
  @core_async.run_async_main(async fn() {
    let session_backend : Ref[@extra_session.ConsoleSessionBackend?] = Ref(None)
    defer (if session_backend.val is Some(backend) { (backend.close)() })
    @core_async.with_task_group(async fn(group) {
      // Match cetas-js: the outer group owns I/O work (including MCP
      // subprocesses); the inner group owns MCP actors and recovery tasks.
      @core_async.with_task_group(async fn(lifetime_group) {
        let fs_impl = @workspace.NativeWorkspaceFs()
        let fs : &@workspace.WorkspaceFs = fs_impl
        let cwd = @env.current_dir().unwrap_or(".")
        let home = @cetas_core.cetas_home()
        match @extra_session.backend_factory() {
          Some(factory) =>
            match factory(home) {
              Ok(backend) => session_backend.val = Some(backend)
              Err(detail) => {
                emit(
                  Json::object({
                    "type": Json::string("infra.boot"),
                    "status": Json::string("error"),
                    "boot_state": Json::string("error"),
                    "detail": Json::string(detail),
                  }).stringify(),
                )
                return
              }
            }
          None => ()
        }
        // The terminal is the one consumer that opts into the full realtime UI
        // projection (tool phases, argument deltas, Custom/scope attribution,
        // ledger facts, unflattened UiRender); every other console consumer keeps
        // the shared default contract.
        let config = @console.console_config(
          fs,
          home,
          "cetas-go",
          "cetas-go/0.1",
          native_ui=true,
          // Only a verified and opted-in Bun may compose native Pi tools.
          native_pi_enabled=@env.get_env_var("CETAS_NATIVE_PI_ENABLED")
            is Some("1"),
          // Native terminal default: yolo, like the JS shell, where the console's
          // shared default stays WorkspaceWrite; an explicit runtime `/permission`
          // still wins afterwards.
          permission_mode=@permission.PermissionMode::Yolo,
          // The terminal owns its pane: report agent state to herdr like the JS
          // and run hosts. Env-gated, so nothing registers outside a pane.
          herdr_presence=true,
          session_backend=session_backend.val,
        )
        let boot : Ref[Result[@console.ConsoleRuntime, String]] = Ref(
          Err("connecting"),
        )
        let composing = Ref(true)
        // Settled once by the compose task: whether the error state is the clean
        // missing-provider setup (first-run onboarding) rather than a fatal
        // failure. The dispatcher routes on this flag instead of re-sniffing the
        // error text every frame.
        let needs_setup = Ref(false)
        let setup = @console.console_bootstrap(
          fs,
          home,
          fn(frame) { emit(frame) },
          native_ui=true,
        )
        let setup_tasks = NativeBootstrapTasks::new()
        // Composition is disk-heavy (settings, credentials, model cache, recipe, a
        // whole first agent), so it runs on the background group: the command loop
        // below serves ping/state immediately while progress frames stream to the
        // terminal.
        ignore(
          group.spawn(
            async fn() {
              // Whatever ends this task — completion, error, cancellation — the
              // shutdown epilogue waits on this flag, so a raise in the middle must
              // never park it at `true` forever.
              defer {
                composing.val = false
              }
              let started = @core_async.now()
              emit_boot_progress("composing", 0)
              // Protected: cancelling the boot mid-build would strand a half-built
              // workspace whose session scopes parked on close signals nobody would
              // send, and the runtime's deadlock detector aborts the process at group
              // exit. Composition always runs to its install-or-error decision;
              // shutdown waits for it below.
              let composed : Result[@console.ConsoleRuntime, String] = @core_async.protect_from_cancel(async fn() {
                  Ok(
                    @console.compose_console_runtime(
                      config,
                      cwd,
                      group,
                      lifetime_group=Some(lifetime_group),
                    ),
                  ) catch {
                    error => Err(error.to_string())
                  }
                },
              )
              needs_setup.val = match composed {
                Err(detail) =>
                  detail.contains("providers: no configured model provider")
                Ok(_) => false
              }
              boot.val = composed
              emit_boot_progress("composed", @core_async.now() - started)
              match composed {
                Ok(runtime) => {
                  runtime.attach_sink(fn(frame : String) { emit(frame) })
                  emit_snapshot("infra.boot", runtime.runtime_json(), boot=true)
                }
                Err(detail) =>
                  emit(
                    Json::object({
                      "type": Json::string("infra.boot"),
                      "status": Json::string(
                        if needs_setup.val {
                          "needs_setup"
                        } else {
                          "error"
                        },
                      ),
                      "boot_state": Json::string(
                        if needs_setup.val {
                          "needs_setup"
                        } else {
                          "error"
                        },
                      ),
                      "detail": Json::string(detail),
                    }).stringify(),
                  )
              }
            },
            allow_failure=true,
          ),
        )
        let auth_tasks = NativeAuthTasks::new()
        let replay_tasks = NativeReplayTasks::new("native replay")
        let catalog_tasks = NativeReplayTasks::new("native session catalog")
        let harness_buffer = Bytes::make(262144, 0)
        let mut wake_reported = false
        let mut command_wake : @raw_fd.RawFd? = None
        match adopt_command_wake() {
          Ok(wake) => command_wake = Some(wake)
          Err("") =>
            // The expected platform shape: the None branch below polls at 10 ms by
            // design, so no error frame.
            ()
          Err(detail) => {
            emit_degraded("command notification channel unavailable: \{detail}")
            wake_reported = true
          }
        }
        let mut protocol_reported = false
        let wake_buffer = FixedArray::make(1, b'\x00')
        let mut stopping = false
        while !stopping {
          match next_command() {
            0 => {
              let n = next_harness(harness_buffer, harness_buffer.length())
              if n > 0 {
                let raw = @utf8.decode_lossy(harness_buffer[:n])
                if composing.val {
                  // A request that raced composition cannot be served yet: reply
                  // with a named refusal, never a silent drop.
                  reject_while_composing(raw)
                } else {
                  match boot.val {
                    Ok(runtime) =>
                      harness_handle_frame(
                        runtime, auth_tasks, replay_tasks, catalog_tasks, group,
                        raw,
                      )
                    Err(detail) =>
                      if needs_setup.val {
                        bootstrap_handle_frame(
                          setup, setup_tasks, boot, composing, config, cwd, group,
                          lifetime_group, raw,
                        )
                      } else {
                        emit(harness_reply(-1, harness_error(detail)))
                      }
                  }
                }
              } else {
                if n < 0 && !protocol_reported {
                  // A request larger than this dispatcher buffer stays at the FIFO
                  // head and would stall every later request with no trace.
                  // Unreachable while `Submit` enforces the same 256 KiB bound, but
                  // never silent: report the exact sizes once.
                  protocol_reported = true
                  emit(
                    Json::object({
                      "type": Json::string("infra.error"),
                      "detail": Json::string(
                        "harness request does not fit the \{harness_buffer.length()}-byte dispatcher buffer (\{-n} bytes queued); the native request queue cannot advance",
                      ),
                    }).stringify(),
                  )
                }
                match command_wake {
                  Some(wake) => {
                    // One byte per queued item, so a wakeup may coalesce but is
                    // never lost: the queues above are re-read after every wait.
                    let resumed = wake.read_into_once(wake_buffer.mut_view()) catch {
                      error => {
                        if !wake_reported {
                          emit_degraded(
                            "command notification wait failed: \{error}",
                          )
                          wake_reported = true
                        }
                        -1
                      }
                    }
                    if resumed <= 0 {
                      // A failed or closed channel ends this wait for good: the
                      // descriptor is closed and the loop falls back to polling
                      // instead of retrying a dead fd every iteration.
                      if !wake_reported {
                        emit_degraded(
                          "command notification channel closed while waiting (EOF)",
                        )
                        wake_reported = true
                      }
                      wake.close()
                      command_wake = None
                    }
                  }
                  None => @core_async.sleep(10)
                }
              }
            }
            1 =>
              if composing.val {
                emit(
                  Json::object({
                    "type": Json::string("infra.state"),
                    "status": Json::string("connecting"),
                  }).stringify(),
                )
              } else {
                match boot.val {
                  Ok(runtime) =>
                    emit_snapshot("infra.state", runtime.runtime_json())
                  Err(detail) =>
                    emit(
                      Json::object({
                        "type": Json::string("infra.state"),
                        "status": Json::string("needs_setup"),
                        "detail": Json::string(detail),
                      }).stringify(),
                    )
                }
              }
            2 =>
              if composing.val {
                emit("{\"type\":\"infra.ping\",\"status\":\"connecting\"}")
              } else {
                match boot.val {
                  Ok(runtime) => {
                    runtime.emit_event("", "", "infra.ping", extra=[
                      ("source", Json::string("moonbit")),
                    ])
                    emit_snapshot("infra.workspaces", runtime.workspaces_json())
                  }
                  Err(_) =>
                    emit("{\"type\":\"infra.ping\",\"status\":\"needs_setup\"}")
                }
              }
            9 => stopping = true
            other =>
              emit(
                (
                  $|{"type":"infra.error","detail":"unknown command \{other}"}
                ),
              )
          }
        }
        replay_tasks.cancel_all()
        catalog_tasks.cancel_all()
        if !composing.val {
          setup_tasks.cancel_all()
        }
        setup.cancel_all()
        // A shutdown that won the composition race still waits for the protected
        // compose task: once boot.val is final, shutdown_all sweeps every installed
        // handle, and an early break would leave a freshly composed runtime's
        // scopes parked.
        while composing.val {
          @core_async.pause()
        }
        match boot.val {
          Ok(runtime) => {
            // Wake suspended approval/auth coroutines BEFORE draining Posoco: the
            // Go terminal has already requested shutdown and cannot answer an
            // outstanding UiPort request anymore.
            auth_tasks.cancel_all()
            runtime.cancel_pending_ui()
            runtime.detach_sink()
            runtime.shutdown_all()
          }
          // No agent ever owned a Lifecycle, so nobody else releases the pane:
          // a composition that failed after detection registered herdr would
          // leave the pane showing an agent for this dead process.
          Err(_) => @console.release_herdr_presence()
        }
        emit("{\"type\":\"infra.stopped\",\"status\":\"clean\"}")
        result.val = 1
      })
    })
  })
  result.val
}

///|
/// The POSIX fd helper is excluded on Windows; its native fd type remains
/// an imported interface for the shared bridge package.
#cfg(platform="windows")
#coverage.skip
let _keep_posix_fd_type : Unit = {
  let _ : (@types.Fd) -> Unit = ignore
}
