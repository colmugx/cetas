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

  let warn = async fn(message : String) noraise {
    @stdio.stderr.write(message) catch {
      _ => ()
    }
  }

  @async.with_task_group(group => {
    let (host, native_ui) = @app.NativeHost::compose_interactive(
      home~,
      cwd~,
      mode=@permission.WorkspaceWrite,
      mcp_group=Some(group),
      warn~,
    ) catch {
      error => {
        @stdio.stderr.write(
          "cetas-tui: composition failed: " + error.to_string() + "\n",
        )
        exit(2)
        abort("cetas-tui: unreachable after composition exit")
      }
    }

    ignore(
      host
      .shell()
      .append_notice(
        "cetas-native preview · session " +
        host.session_id() +
        " · Enter submit · Esc interrupt · double-Esc rewind · Ctrl+C exit",
      ),
    )

    let terminal = match @ui.Terminal::open_inline(12U) {
      Some(value) => value
      None => {
        host.shutdown()
        @stdio.stderr.write("cetas-tui: failed to initialize terminal\n")
        exit(2)
        abort("cetas-tui: unreachable after terminal exit")
      }
    }

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
