///|
/// Native Cetas terminal entrypoint.
///
/// This is intentionally a narrow product loop: shared Cetas composition,
/// Ratatui inline terminal, streaming Agent turns, follow-up queueing,
/// interrupts, and interactive UiPort/approval requests are live. Higher
/// command/modal flows continue to migrate behind NativeLoopSignal.
extern "C" fn exit(code : Int) = "exit"

///|
fn startup_permission_mode(
  raw : String?,
) -> (@permission.PermissionMode, String?) {
  match raw {
    None => (@permission.Yolo, None)
    Some("readonly") => (@permission.ReadOnly, None)
    Some("workspace_write") => (@permission.WorkspaceWrite, None)
    Some("interactive") => (@permission.Interactive, None)
    Some("auto") => (@permission.Auto, None)
    Some("yolo") => (@permission.Yolo, None)
    Some(value) =>
      (
        @permission.WorkspaceWrite,
        Some(
          "CETAS_PERMISSION_MODE '" +
          value +
          "' is not one of readonly/workspace_write/interactive/auto/yolo; using workspace_write",
        ),
      )
  }
}

///|
fn startup_banner(
  model : String,
  effort : String?,
  session_id : String,
) -> String {
  let active_model = if model.is_empty() { "no active model" } else { model }
  let active_effort = match effort {
    Some(value) if !value.is_empty() => " · effort " + value
    _ => ""
  }
  "Cetas 0.7.0 · model " +
  active_model +
  active_effort +
  " · session " +
  session_id
}

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
    let (permission_mode, permission_warning) = startup_permission_mode(
      @env.get_env_var("CETAS_PERMISSION_MODE"),
    )
    match permission_warning {
      Some(message) => startup_warnings.push(message)
      None => ()
    }

    let composed : Result[(@app.NativeHost, @app.NativeUiPort), Error] = Ok(
      @app.NativeHost::compose_interactive(
        home~,
        cwd~,
        mode=permission_mode,
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

    ignore(
      host
      .shell()
      .append_notice(
        startup_banner(
          host.active_model(),
          host.active_effort(),
          host.session_id(),
        ),
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
                ignore(
                  app.append_error("rewind points failed: " + error.to_string()),
                )
                false
              }
            },
          )
        @app.LoopApplyRewind(message_index) =>
          app.apply_rewind(message_index) catch {
            error =>
              ignore(app.append_error("rewind failed: " + error.to_string()))
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
          "cetas: terminal failure (" + status.to_string() + ")\n",
        )
        exit(1)
      }
      None => ()
    }
  })
}
