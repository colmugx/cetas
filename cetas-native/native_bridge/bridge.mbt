///|
/// Cetas native host: Cetas runtime is owned by a single Go-locked OS thread.

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
fn emit(frame : String) -> Unit {
  let data = @utf8.encode(frame)
  ignore(publish(data, data.length()))
}

///|
/// Run a single-owner async domain on a locked Go worker OS thread.
/// Real ConsoleRuntime construction is attempted, never fabricated.
#export_name("cetas_infra_run")
pub fn run_infra() -> Int32 {
  let result = Ref(0)
  @async.run_async_main(async fn() {
    @async.with_task_group(group => {
      let fs_impl = @workspace.NativeWorkspaceFs()
      let fs : &@workspace.WorkspaceFs = fs_impl
      let cwd = @env.current_dir().unwrap_or(".")
      let home = @cetas_core.cetas_home()
      let config = @console.console_config(
        fs, home, "cetas-native", "cetas-native/0.1",
      )
      let boot : Ref[Result[@console.ConsoleRuntime, String]] = Ref(
        Ok(@console.compose_console_runtime(config, cwd, group)) catch {
          error => Err(error.to_string())
        },
      )
      let setup = @console.console_bootstrap(fs, home, fn(frame) { emit(frame) })
      let setup_tasks = NativeBootstrapTasks::new()
      match boot.val {
        Ok(runtime) => {
          runtime.attach_sink(fn(frame : String) { emit(frame) })
          emit(
            "{\"type\":\"infra.boot\",\"status\":\"ready\",\"snapshot\":" +
            runtime.runtime_json().stringify() +
            "}",
          )
        }
        Err(detail) =>
          emit(
            Json::object({
              "type": Json::string("infra.boot"),
              "status": Json::string(
                if detail.contains("providers: no configured model provider") {
                  "needs_setup"
                } else {
                  "error"
                },
              ),
              "detail": Json::string(detail),
            }).stringify(),
          )
      }
      let auth_tasks = NativeAuthTasks::new()
      let harness_buffer = Bytes::make(262144, 0)
      let mut stopping = false
      while !stopping {
        match next_command() {
          0 => {
            let n = next_harness(harness_buffer, harness_buffer.length())
            if n > 0 {
              let raw = @utf8.decode_lossy(harness_buffer[:n])
              match boot.val {
                Ok(runtime) =>
                  harness_handle_frame(runtime, auth_tasks, group, raw)
                Err(detail) =>
                  if detail.contains("providers: no configured model provider") {
                    bootstrap_handle_frame(
                      setup, setup_tasks, boot, config, cwd, group, raw,
                    )
                  } else {
                    emit(harness_reply(-1, harness_error(detail)))
                  }
              }
            } else {
              @async.sleep(10)
            }
          }
          1 =>
            match boot.val {
              Ok(runtime) =>
                emit(
                  "{\"type\":\"infra.state\",\"snapshot\":" +
                  runtime.runtime_json().stringify() +
                  "}",
                )
              Err(detail) =>
                emit(
                  Json::object(
                    Map::from_array([
                      ("type", Json::string("infra.state")),
                      ("status", Json::string("needs_setup")),
                      ("detail", Json::string(detail)),
                    ]),
                  ).stringify(),
                )
            }
          2 =>
            match boot.val {
              Ok(runtime) => {
                runtime.emit_event("", "", "infra.ping", extra=[
                  ("source", Json::string("moonbit")),
                ])
                emit(
                  "{\"type\":\"infra.workspaces\",\"snapshot\":" +
                  runtime.workspaces_json().stringify() +
                  "}",
                )
              }
              Err(_) =>
                emit("{\"type\":\"infra.ping\",\"status\":\"needs_setup\"}")
            }
          9 => stopping = true
          other =>
            emit(
              "{\"type\":\"infra.error\",\"detail\":\"unknown command " +
              other.to_string() +
              "\"}",
            )
        }
      }
      setup_tasks.cancel_all()
      setup.cancel_all()
      match boot.val {
        Ok(runtime) => {
          // Wake suspended approval/auth coroutines BEFORE draining Posoco.
          // The Go terminal has already requested shutdown and cannot
          // answer an outstanding UiPort request anymore.
          auth_tasks.cancel_all()
          runtime.cancel_pending_ui()
          runtime.detach_sink()
          runtime.shutdown_all()
        }
        Err(_) => ()
      }
      emit("{\"type\":\"infra.stopped\",\"status\":\"clean\"}")
      result.val = 1
    })
  })
  result.val
}
