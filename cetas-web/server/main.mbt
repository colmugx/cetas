///|
/// cetas-web transport adaptor: HTTP routes plus one WebSocket broadcast
/// stream over the shared cetas-console core. Business logic lives in the
/// console; this package only translates between HTTP/WS and its calls.

///|
const WEB_EVENT_QUEUE_CAPACITY : Int = 4096

// Keep in sync with moon.mod pins: colmugx/posoco, colmugx/cetas-core, colmugx/cetas-web.

///|
const POSOCO_VERSION : String = "0.22.0"

///|
const CETAS_VERSION : String = "0.2.0"

///|
const WEB_VERSION : String = "0.1.0"

///|
async fn drain_web_events(
  queue : @aqueue.Queue[String],
  ws : @websocket.Conn,
) -> Unit noraise {
  while true {
    let event = queue.get() catch { _ => break }
    ws.send_text(event) catch {
      _ => break
    }
  }
}

///|
fn error_json(message : String) -> Json {
  Json::object(Map::from_array([("error", Json::string(message))]))
}

///|
async fn request_string_field(req : @moonback.Request, key : String) -> String? {
  let body = req.body.json() catch { _ => return None }
  guard body is Json::Object(fields) else { return None }
  match fields.get(key) {
    Some(Json::String(value)) => Some(value)
    _ => None
  }
}

///|
async fn serve_websocket(
  req : @moonback.Request,
  res : @moonback.Responder,
  boot : Result[@console.ConsoleRuntime, String],
) -> Unit {
  let ws = res.upgrade(req)
  let client_ip = req.ip().unwrap_or("unknown")
  println("cetas-web websocket connected from \{client_ip}")
  defer ws.close()

  match boot {
    Err(detail) =>
      ws.send_text(
        Json::object(
          Map::from_array([
            ("type", Json::string("runtime.unavailable")),
            ("protocol", Json::string("cetas-web/0.1")),
            ("message", Json::string(detail)),
          ]),
        ).stringify(),
      )
    Ok(runtime) =>
      @async.with_task_group(connection_group => {
        let queue : @aqueue.Queue[String] = Queue(
          kind=Blocking(WEB_EVENT_QUEUE_CAPACITY),
        )
        runtime.attach_sink(fn(event : String) {
          ignore(queue.try_put(event) catch { _ => false })
        })
        defer runtime.detach_sink()
        defer queue.close(clear=true)

        connection_group.spawn_bg(async fn() { drain_web_events(queue, ws) })

        runtime.emit_event("", "", "connection.ready", extra=[
          ("protocol", Json::string("cetas-web/0.1")),
        ])

        try {
          for ;; {
            let msg = ws.recv()
            match msg.kind {
              Text => {
                let raw = msg.read_all().text()
                match decode_web_client_message(raw) {
                  Err(message) =>
                    runtime.emit_event("", "", "protocol.error", extra=[
                      ("message", Json::string(message)),
                    ])
                  Ok(SessionAttach) => {
                    runtime.emit_active_snapshot()
                    runtime.republish_status()
                  }
                  Ok(TurnStart(prompt, session_id)) =>
                    match runtime.start_turn(prompt, session_id) {
                      Ok(_) => ()
                      Err(message) =>
                        runtime.emit_event("", "", "protocol.error", extra=[
                          ("message", Json::string(message)),
                        ])
                    }
                  Ok(TurnAbort(session_id)) => runtime.abort_turn(session_id)
                  Ok(SessionCompact) => runtime.compact_active_session()
                  Ok(StatusRefresh(session_id)) => {
                    // /status-style pull: live-read the active provider's
                    // quota source and push readings to the strip/window,
                    // then the all-providers map for the expanded view.
                    let payload : Json = runtime.quota_json() catch {
                      error => error_json(error.to_string())
                    }
                    let sid = match session_id {
                      Some(id) => id
                      None => runtime.active_session_id()
                    }
                    runtime.emit_event(sid, "", "statusbar.quota", extra=[
                      ("payload", payload),
                    ])
                    let all_payload : Json = runtime.quota_all_json() catch {
                      error => error_json(error.to_string())
                    }
                    runtime.emit_event(sid, "", "statusbar.quota_all", extra=[
                      ("payload", all_payload),
                    ])
                  }
                  Ok(UiResponse(request_id)) =>
                    runtime.resolve_ui(request_id, raw)
                }
              }
              Binary =>
                runtime.emit_event("", "", "protocol.error", extra=[
                  (
                    "message",
                    Json::string("binary websocket messages are not supported"),
                  ),
                ])
            }
          }
        } catch {
          @websocket.ConnectionClosed(code, reason) =>
            println(
              "cetas-web websocket closed from \{client_ip}: \{@debug.to_string(code)}, reason=\{@debug.to_string(reason)}",
            )
          err => println("cetas-web websocket error from \{client_ip}: \{err}")
        }
      })
  }
}

///|
async fn main {
  let assets = web_assets()
  let dist = @env.get_env_var("CETAS_WEB_DIST").unwrap_or(
    "cetas-web/web/dist/client",
  )
  let static_files = if assets.is_empty() {
    @unstable_static.new(root=dist, history_fallback=Some("/index.html"))
  } else {
    @unstable_static.from_assets(assets, history_fallback=Some("/index.html"))
  }

  let home = @cetas_core.cetas_home()
  let cwd = @env.current_dir().unwrap_or(".")
  let fs_impl = @workspace.NativeWorkspaceFs()
  let fs : &@workspace.WorkspaceFs = fs_impl
  let config = @console.console_config(fs, home, "cetas-web", "cetas-web/0.1")

  @async.with_task_group(group => {
    let boot : Result[@console.ConsoleRuntime, String] = Ok(
      @console.compose_console_runtime(config, cwd, group),
    ) catch {
      error => Err(error.to_string())
    }

    let api = @moonback.App(ctx => {
      ctx.get("/health", (_req, res) => {
        res.send_json({ "status": "ok", "host": "cetas-web", "protocol": "0.1" })
      })
      ctx.get("/versions", (_req, res) => {
        res.send_json({
          "posoco": POSOCO_VERSION,
          "cetas": CETAS_VERSION,
          "web": WEB_VERSION,
        })
      })
      ctx.get("/runtime", (_req, res) => {
        match boot {
          Ok(runtime) => res.send_json(runtime.runtime_json())
          Err(detail) =>
            res.send_json({
              "status": "needs_setup",
              "session_id": "",
              "model": "",
              "effort": "",
              "cwd": cwd,
              "permission": "",
              "detail": detail,
            })
        }
      })
      ctx.get("/sessions", (_req, res) => {
        match boot {
          Ok(runtime) => {
            let payload : Json = runtime.sessions_json() catch {
              error => error_json(error.to_string())
            }
            res.send_json(payload)
          }
          Err(detail) => res.send_json(error_json(detail), status=503)
        }
      })
      ctx.get("/sessions/:id/transcript", (req, res) => {
        match boot {
          Ok(runtime) =>
            match req.params.get("id") {
              Some(id) => {
                let payload : Json = runtime.transcript_json(id.to_owned()) catch {
                  _ => @console.transcript_empty_json()
                }
                res.send_json(payload)
              }
              None => res.send_json(error_json("missing id"), status=400)
            }
          Err(detail) => res.send_json(error_json(detail), status=503)
        }
      })
      ctx.post("/sessions/:id/rename", (req, res) => {
        match boot {
          Ok(runtime) =>
            match req.params.get("id") {
              Some(id) =>
                match request_string_field(req, "name") {
                  Some(name) =>
                    match runtime.rename_session(id.to_owned(), name) {
                      Ok(_) => res.send_json({ "ok": true })
                      Err(message) =>
                        res.send_json(error_json(message), status=409)
                    }
                  None =>
                    res.send_json(
                      error_json("body must include name"),
                      status=400,
                    )
                }
              None => res.send_json(error_json("missing id"), status=400)
            }
          Err(detail) => res.send_json(error_json(detail), status=503)
        }
      })
      ctx.get("/exts", (_req, res) => {
        match boot {
          Ok(runtime) => res.send_json(runtime.zoo_json())
          Err(detail) => res.send_json(error_json(detail), status=503)
        }
      })
      ctx.get("/files/search", (req, res) => {
        match boot {
          Ok(runtime) => {
            let query = match req.query().get("q") {
              Some(q) => q
              None => ""
            }
            let payload : Json = runtime.file_suggestions_json(query, 50) catch {
              error => error_json(error.to_string())
            }
            res.send_json(payload)
          }
          Err(detail) => res.send_json(error_json(detail), status=503)
        }
      })
      ctx.get("/skills", (_req, res) => {
        match boot {
          Ok(runtime) => {
            let payload : Json = runtime.skills_json() catch {
              error => error_json(error.to_string())
            }
            res.send_json(payload)
          }
          Err(detail) => res.send_json(error_json(detail), status=503)
        }
      })
      ctx.get("/trace", (req, res) => {
        match boot {
          Ok(runtime) => {
            let payload : Json = runtime.trace_json(
              req.query().get("session"),
              req.query().get("turn"),
            )
            res.send_json(payload)
          }
          Err(detail) => res.send_json(error_json(detail), status=503)
        }
      })
      ctx.get("/workspaces", (_req, res) => {
        match boot {
          Ok(runtime) => res.send_json(runtime.workspaces_json())
          Err(detail) => res.send_json(error_json(detail), status=503)
        }
      })
      ctx.post("/workspaces", (req, res) => {
        match boot {
          Ok(runtime) =>
            match request_string_field(req, "cwd") {
              Some(cwd) =>
                match runtime.switch_workspace(cwd) {
                  Ok(_) => res.send_json(runtime.workspaces_json())
                  Err(message) => res.send_json(error_json(message), status=409)
                }
              None =>
                res.send_json(error_json("body must include cwd"), status=400)
            }
          Err(detail) => res.send_json(error_json(detail), status=503)
        }
      })
      ctx.post("/session", (req, res) => {
        match boot {
          Ok(runtime) => {
            let requested = request_string_field(req, "id")
            let outcome : Result[String, String] = match requested {
              Some(id) => runtime.switch_session(id)
              None => runtime.new_session()
            }
            match outcome {
              Ok(session_id) => res.send_json({ "session_id": session_id })
              Err(message) => res.send_json(error_json(message), status=409)
            }
          }
          Err(detail) => res.send_json(error_json(detail), status=503)
        }
      })
      ctx.get("/models", (_req, res) => {
        match boot {
          Ok(runtime) => res.send_json(runtime.model_slots_json(None))
          Err(detail) => res.send_json(error_json(detail), status=503)
        }
      })
      ctx.post("/model", (req, res) => {
        match boot {
          Ok(runtime) =>
            match request_string_field(req, "slot_id") {
              Some(slot_id) => {
                let session_id = request_string_field(req, "session_id")
                match runtime.switch_model(slot_id, session_id) {
                  Ok(_) => res.send_json(runtime.runtime_json())
                  Err(message) => res.send_json(error_json(message), status=409)
                }
              }
              None =>
                res.send_json(
                  error_json("body must include slot_id"),
                  status=400,
                )
            }
          Err(detail) => res.send_json(error_json(detail), status=503)
        }
      })
      ctx.post("/effort", (req, res) => {
        match boot {
          Ok(runtime) =>
            match request_string_field(req, "effort") {
              Some(effort) =>
                match runtime.select_effort(effort, None) {
                  Ok(_) => res.send_json(runtime.runtime_json())
                  Err(message) => res.send_json(error_json(message), status=409)
                }
              None =>
                res.send_json(
                  error_json("body must include effort"),
                  status=400,
                )
            }
          Err(detail) => res.send_json(error_json(detail), status=503)
        }
      })
      ctx.post("/permission", (req, res) => {
        match boot {
          Ok(runtime) =>
            match request_string_field(req, "mode") {
              Some(mode) =>
                match runtime.set_permission(mode) {
                  Ok(_) => res.send_json(runtime.runtime_json())
                  Err(message) => res.send_json(error_json(message), status=409)
                }
              None =>
                res.send_json(error_json("body must include mode"), status=400)
            }
          Err(detail) => res.send_json(error_json(detail), status=503)
        }
      })
    })

    let app = @moonback.App(ctx => {
      ctx.add_middleware(static_files)
      ctx.mount("/api", api)
      ctx.get("/ws", (req, res) => serve_websocket(req, res, boot))
    })
    defer app.close()

    let host = "127.0.0.1"
    let port = 8787
    match boot {
      Ok(runtime) =>
        println(
          "cetas-web: core ready workspace=\{runtime.active_workspace()} session=\{runtime.active_session_id()}",
        )
      Err(detail) => println("cetas-web: core needs setup: \{detail}")
    }
    println("cetas-web: http://\{host}:\{port}")
    println("cetas-web: websocket ws://\{host}:\{port}/ws")
    app.serve(@moonback.listen(host~, port=port.to_uint16(), reuse_addr=true))

    match boot {
      Ok(runtime) => runtime.shutdown_all()
      Err(_) => ()
    }
  })
}
