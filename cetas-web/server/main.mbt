///|
async fn serve_websocket(
  req : @moonback.Request,
  res : @moonback.Responder,
) -> Unit {
  let ws = res.upgrade(req)
  let client_ip = req.ip().unwrap_or("unknown")
  println("cetas-web websocket connected from \{client_ip}")
  defer ws.close()
  ws.send_text("{\"type\":\"connected\",\"protocol\":\"cetas-web/0\"}")
  try {
    for ;; {
      let msg = ws.recv()
      match msg.kind {
        Text => {
          let text = msg.read_all().text()
          ws.send_text(text)
        }
        Binary => {
          let data = msg.read_all().binary()
          ws.send_binary(data)
        }
      }
    }
  } catch {
    @websocket.ConnectionClosed(code, reason) =>
      println(
        "cetas-web websocket closed from \{client_ip}: \{@debug.to_string(code)}, reason=\{@debug.to_string(reason)}",
      )
    err => println("cetas-web websocket error from \{client_ip}: \{err}")
  }
}

///|
async fn main {
  let assets = web_assets()
  let dist = @env.get_env_var("CETAS_WEB_DIST").unwrap_or(
    "cetas-web/web/dist/client",
  )
  let static_files = if assets.is_empty() {
    @unstable_static.new(
      root=dist,
      history_fallback=Some("/index.html"),
    )
  } else {
    @unstable_static.from_assets(
      assets,
      history_fallback=Some("/index.html"),
    )
  }

  let api = @moonback.App(ctx => {
    ctx.get("/health", (_req, res) => {
      res.send_json({
        "status": "ok",
        "host": "cetas-web",
        "protocol": "0",
      })
    })
  })

  let app = @moonback.App(ctx => {
    ctx.add_middleware(static_files)
    ctx.mount("/api", api)
    ctx.get("/ws", serve_websocket)
  })
  defer app.close()

  let host = "127.0.0.1"
  let port = 8787
  println("cetas-web: http://\{host}:\{port}")
  println("cetas-web: websocket ws://\{host}:\{port}/ws")
  app.serve(@moonback.listen(host~, port=port.to_uint16(), reuse_addr=true))
}
