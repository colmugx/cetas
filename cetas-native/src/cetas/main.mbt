///|
/// Native Cetas terminal entrypoint.
///
/// This is intentionally a narrow product loop: shared Cetas composition,
/// Ratatui inline terminal, streaming Agent turns, follow-up queueing,
/// interrupts, and interactive UiPort/approval requests are live. Higher
/// command/modal flows continue to migrate behind NativeLoopSignal.
extern "C" fn exit(code : Int) = "exit"

///|
fn mint_login_device_id() -> String raise @posoco.CommandError {
  let bytes = match @env.rand(16) {
    Some(value) if value.length() == 16 => value
    _ =>
      raise @posoco.CommandError::ExecutionFailed(
        "Cannot mint persistent login device id",
      )
  }
  let hex = "0123456789abcdef"
  let out = StringBuilder()
  for i in 0..<16 {
    if i == 4 || i == 6 || i == 8 || i == 10 {
      out.write_string("-")
    }
    let byte = if i == 6 {
      (bytes[i].to_int() & 15) | 64
    } else if i == 8 {
      (bytes[i].to_int() & 63) | 128
    } else {
      bytes[i].to_int()
    }
    out.write_string(hex[byte >> 4:(byte >> 4) + 1].to_owned())
    out.write_string(hex[byte & 15:(byte & 15) + 1].to_owned())
  }
  out.to_string()
}

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

    let mut ready : (@app.NativeHost, @app.NativeUiPort)? = None
    while ready is None {
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
      match composed {
        Ok(value) => ready = Some(value)
        Err(error) => {
          for warning in startup_warnings {
            ignore(terminal.insert_before("· " + warning))
          }
          startup_warnings.clear()
          let setup = @app.NativeSetupLoop::new(
            terminal,
            "Cetas setup failed: " + error.to_string(),
          )
          let mut retry = false
          while !retry {
            match setup.run_until_signal() {
              @app.SetupContinue => ()
              @app.SetupRetry => retry = true
              @app.SetupExit => {
                terminal.close()
                exit(0)
                abort("cetas: unreachable after setup exit")
              }
              @app.SetupLogin(provider) => {
                let auth = setup.auth_ui()
                setup.set_command_busy(true)
                let login_task = group.spawn(
                  () =>
                    @cetas_core.run_provider_login_flow(
                      home~,
                      provider~,
                      @workspace.NativeWorkspaceFs(),
                      auth as &@oauth.AuthInteraction,
                      auth as &@oauth.AuthPromptInteraction,
                      mint_login_device_id,
                      note=async fn(message : String) noraise {
                        @async.sleep(0)
                        let trimmed = message.trim().to_owned()
                        if !trimmed.is_empty() {
                          ignore(setup.append_notice(trimmed))
                        }
                      },
                    ),
                  allow_failure=true,
                )
                let mut auth_running = true
                while auth_running {
                  let settled : Result[Unit?, Error] = Ok(login_task.try_wait()) catch {
                    login_error => Err(login_error)
                  }
                  match settled {
                    Ok(Some(_)) => {
                      setup.set_command_busy(false)
                      ignore(
                        setup.append_notice(
                          "Authentication finished; retrying Cetas composition.",
                        ),
                      )
                      retry = true
                      auth_running = false
                    }
                    Ok(None) =>
                      match setup.tick() {
                        @app.SetupContinue => @async.sleep(8)
                        @app.SetupExit => {
                          auth.cancel()
                          login_task.cancel()
                          ignore(login_task.wait()) catch {
                            _ => ()
                          }
                          terminal.close()
                          exit(0)
                          abort("cetas: unreachable after setup auth exit")
                        }
                        @app.SetupTerminalFailed(status) => {
                          auth.cancel()
                          login_task.cancel()
                          ignore(login_task.wait()) catch {
                            _ => ()
                          }
                          terminal.close()
                          @stdio.stderr.write(
                            "cetas: setup terminal failure (" +
                            status.to_string() +
                            ")\n",
                          )
                          exit(1)
                          abort("cetas: unreachable after setup auth terminal failure")
                        }
                        _ => ()
                      }
                    Err(login_error) => {
                      setup.set_command_busy(false)
                      ignore(
                        setup.append_error(
                          "login failed: " + login_error.to_string(),
                        ),
                      )
                      auth_running = false
                    }
                  }
                }
              }
              @app.SetupTerminalFailed(status) => {
                terminal.close()
                @stdio.stderr.write(
                  "cetas: setup terminal failure (" + status.to_string() + ")\n",
                )
                exit(1)
                abort("cetas: unreachable after setup terminal failure")
              }
            }
          }
        }
      }
    }
    let (host, native_ui) = match ready {
      Some(value) => value
      None => abort("cetas: setup loop exited without a composed host")
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

    let mut app = @app.NativeAppLoop::new(host, native_ui, terminal)
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
                  app.append_error(
                    "rewind points failed: " + error.to_string(),
                  ),
                )
                false
              }
            },
          )
        @app.LoopApplyRewind(message_index) =>
          app.apply_rewind(message_index) catch {
            error =>
              ignore(
                app.append_error("rewind failed: " + error.to_string()),
              )
          }
        @app.LoopAutocomplete
        | @app.LoopToggleThinking
        | @app.LoopToggleToolOutput =>
          ()
        @app.LoopLogin(provider) => {
          let auth_app = app
          let auth = auth_app.auth_ui()
          auth_app.acquire_command("authenticating provider")
          let login_task = group.spawn(
            () =>
              @cetas_core.run_provider_login_flow(
                home~,
                provider~,
                @workspace.NativeWorkspaceFs(),
                auth as &@oauth.AuthInteraction,
                auth as &@oauth.AuthPromptInteraction,
                mint_login_device_id,
                note=async fn(message : String) noraise {
                  @async.sleep(0)
                  let trimmed = message.trim().to_owned()
                  if !trimmed.is_empty() {
                    ignore(auth_app.append_notice(trimmed))
                  }
                },
              ),
            allow_failure=true,
          )
          let mut auth_running = true
          while auth_running && running {
            let settled : Result[Unit?, Error] = Ok(login_task.try_wait()) catch {
              login_error => Err(login_error)
            }
            match settled {
              Ok(Some(_)) => {
                let session_id = auth_app.session_id()
                let recomposed : Result[
                  (@app.NativeHost, @app.NativeUiPort),
                  Error,
                ] = Ok(
                  @app.NativeHost::compose_interactive(
                    home~,
                    cwd~,
                    mode=permission_mode,
                    session_id~,
                    mcp_group=Some(group),
                    warn~,
                  ),
                ) catch {
                  compose_error => Err(compose_error)
                }
                match recomposed {
                  Ok((next_host, next_ui)) => {
                    ignore(
                      next_host
                      .shell()
                      .append_notice(
                        "Authentication refreshed · " +
                        startup_banner(
                          next_host.active_model(),
                          next_host.active_effort(),
                          next_host.session_id(),
                        ),
                      ),
                    )
                    auth_app.shutdown_for_recompose()
                    app = @app.NativeAppLoop::new(next_host, next_ui, terminal)
                  }
                  Err(compose_error) => {
                    ignore(auth_app.release_command())
                    ignore(
                      auth_app.append_error(
                        "authentication saved, but provider refresh failed: " +
                        compose_error.to_string(),
                      ),
                    )
                  }
                }
                auth_running = false
              }
              Ok(None) =>
                match auth_app.tick(group) {
                  @app.LoopContinue
                  | @app.LoopAutocomplete
                  | @app.LoopToggleThinking
                  | @app.LoopToggleToolOutput
                  | @app.LoopDismissOverlay => @async.sleep(8)
                  @app.LoopExit => {
                    auth.cancel()
                    login_task.cancel()
                    try {
                      let _ = login_task.wait()
                    } catch {
                      _ => ()
                    }
                    auth_running = false
                    running = false
                  }
                  @app.LoopTerminalFailed(status) => {
                    auth.cancel()
                    login_task.cancel()
                    try {
                      let _ = login_task.wait()
                    } catch {
                      _ => ()
                    }
                    terminal_failure = Some(status)
                    auth_running = false
                    running = false
                  }
                  _ => ()
                }
              Err(login_error) => {
                ignore(auth_app.release_command())
                ignore(
                  auth_app.append_error(
                    "login failed: " + login_error.to_string(),
                  ),
                )
                auth_running = false
              }
            }
          }
        }
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
