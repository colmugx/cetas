///|
/// cetas-tui native preview entrypoint.
///
/// This is intentionally a narrow product loop: real Cetas composition,
/// Ratatui inline terminal, streaming Agent turns, follow-up queueing,
/// interrupts, and interactive UiPort/approval requests are live. Higher
/// command/modal flows continue to migrate behind NativeLoopSignal.
extern "C" fn exit(code : Int) = "exit"

///|
async fn main {
  let home = @cetas_core.cetas_home()
  let cwd = match @env.current_dir() {
    Some(dir) => dir
    None => "."
  }

  @async.with_task_group(group => {
    let terminal = match @ui.Terminal::open_inline(12U) {
      Some(value) => value
      None => {
        @stdio.stderr.write("cetas: failed to initialize terminal\n")
        exit(2)
        abort("cetas: unreachable after terminal exit")
      }
    }

    let startup_warnings : Array[String] = []
    let warn = async fn(message : String) noraise {
      @async.sleep(0)
      let trimmed = message.trim().to_owned()
      if !trimmed.is_empty() {
        startup_warnings.push(trimmed)
      }
    }

    let composed : Result[( @app.NativeHost, @app.NativeUiPort ), Error] = Ok(
      @app.NativeHost::compose_interactive(
        home~,
        cwd~,
        mode=@permission.WorkspaceWrite,
        mcp_group=Some(group),
        warn~,
      ),
    ) catch {
      error => Err(error)
    }
    let (host, native_ui) = match composed {
      Ok(value) => value
      Err(error) => {
        for warning in startup_warnings {
          ignore(terminal.insert_before("· " + warning))
        }
        ignore(
          terminal.insert_before(
            "● error: Cetas setup failed: " + error.to_string(),
          ),
        )
        terminal.close()
        exit(2)
        abort("cetas: unreachable after composition exit")
      }
    }

    let model = if host.active_model().is_empty() {
      "no active model"
    } else {
      host.active_model()
    }
    let effort = match host.active_effort() {
      Some(value) if !value.is_empty() => " · effort " + value
      _ => ""
    }
    ignore(
      host
      .shell()
      .append_notice(
        "Cetas 0.7.0 · model " +
        model +
        effort +
        " · session " +
        host.session_id(),
      ),
    )
    for warning in startup_warnings {
      ignore(host.shell().append_notice(warning))
    }
    ignore(
      host
      .shell()
      .append_notice(
        "Enter submit · Esc interrupt · double-Esc rewind · Ctrl+C exit",
      ),
    )

    let app = @app.NativeAppLoop::new(host, native_ui, terminal)
    let mut running = true
    let mut terminal_failure : Int? = None

    while running {
      match app.run_until_signal(group) {
        @app.LoopContinue => ()
        @app.LoopExit => running = false
        @app.LoopDismissOverlay => app.set_dismissible_overlay_visible(false)
        @app.LoopOpenRewind =>
          ignore(
            app.open_rewind() catch {
              error => {
                @stdio.stderr.write(
                  "cetas-tui: rewind points failed: " + error.to_string() + "\n",
                )
                false
              }
            },
          )
        @app.LoopApplyRewind(message_index) =>
          app.apply_rewind(message_index) catch {
            error =>
              @stdio.stderr.write(
                "cetas-tui: rewind failed: " + error.to_string() + "\n",
              )
          }
        @app.LoopAutocomplete
        | @app.LoopToggleThinking
        | @app.LoopToggleToolOutput =>
          // These product presentation flows are still migrating behind the
          // stable loop signal boundary.
          ()
        @app.LoopTerminalFailed(status) => {
          terminal_failure = Some(status)
          running = false
        }
      }
    }

    app.shutdown()
    match terminal_failure {
      Some(status) => {
        @stdio.stderr.write(
          "cetas-tui: terminal failure (" + status.to_string() + ")\n",
        )
        exit(1)
      }
      None => ()
    }
  })
}
