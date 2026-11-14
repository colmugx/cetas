///|
/// Retention probes for the per-turn memory investigation, each as one
/// self-contained test with its own loopback SSE server (no external
/// process). The four variants isolate one layer each:
///
/// 1. "in-process streaming port" — the full cetas-core session assembly
///    with a fake model port that streams content-sized answers through the
///    caller's on_chunk. Control: this configuration is measured FLAT.
/// 2. "http custom port" — the same assembly with the production
///    CustomModelPort (chat-completions over HTTP). Reproduces the per-turn,
///    content-carried retention seen in the harness.
/// 3. "raw http under composition" — the same assembly, but the model port
///    only POSTs a conversation-sized body and reads the whole response
///    back; no SSE parsing. Splits the transport from the SSE decode path.
/// 4. "raw http no agent" — the same POST loop with no session, no agent,
///    no composition: the bare HTTP transport, no session lifetime.
///
/// These are diagnostics, not pass/fail memory assertions: they assert only
/// that the turns complete, and print MARK lines so an external RSS sampler
/// can correlate growth with depth. Keep the turn counts low enough that
/// the suite stays fast; the retention signal is multiples of content size
/// per turn and stays unmistakable at this scale.

///|
/// These probes need the standalone mock SSE provider (tools/mockprovider)
/// listening on 127.0.0.1:8933. Gate on a sentinel file so ordinary
/// `moon test` runs skip them instantly instead of hanging on a dead port.
async fn retention_probe_enabled() -> Bool {
  @fs.exists("/tmp/cetas-retain-probe-on") catch {
    _ => false
  }
}

///|
priv struct RetentionModel {
  answer : String
  count : Ref[Int32]
  /// Stream the answer through the caller's on_chunk in ~4 KiB pieces,
  /// mirroring the SSE path's per-piece delivery without any transport.
  stream : Bool
  /// Transport-only probe: POST a request-sized body per call (growing with
  /// the conversation proxy), read the whole response, return the canned
  /// answer. Isolates the raw HTTP path with growing bodies from SSE
  /// parsing.
  http_probe : Bool
  /// Loopback port for the transport-only probe.
  http_probe_port : Int32
}

///|
fn retention_answer(paragraphs : Int32) -> String {
  let parts : Array[String] = []
  let mut paragraph = ""
  for _ in 0..<128 {
    paragraph = paragraph + "0123456789abcdef ghij "
  }
  for i in 0..<paragraphs {
    parts.push("Paragraph \{i}: \{paragraph}\n\n")
  }
  parts.join("")
}

///|
impl @posoco.ModelPort for RetentionModel with fn chat(
  self,
  _scope,
  messages : ArrayView[@posoco.Message],
  _tools,
  _options,
  stream,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  self.count.val = self.count.val + 1
  if self.http_probe {
    let mut total = 0
    for message in messages {
      match message {
        UserMessage(content~) =>
          for block in content {
            match block {
              Text(text) => total = total + text.length()
              _ => ()
            }
          }
        AssistantMessage(content~, ..) =>
          for block in content {
            match block {
              Text(text) => total = total + text.length()
              _ => ()
            }
          }
        _ => ()
      }
    }
    ignore(
      retention_http_probe_post(
        "http://127.0.0.1:\{self.http_probe_port}/v1/chat/completions",
        total,
      ),
    )
  }
  match stream {
    Stream(on_chunk) if self.stream => {
      let mut at = 0
      while at < self.answer.length() {
        let upto = if at + 4096 < self.answer.length() {
          at + 4096
        } else {
          self.answer.length()
        }
        on_chunk(
          @posoco.StreamChunk::TextDelta(token="\{self.answer[at:upto]}"),
        )
        at = upto
      }
    }
    _ => ()
  }
  let completion : @posoco.Completion = @posoco.Completion(
    content=[@posoco.Content::Text(self.answer)],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
    usage=None,
  )
  { completion, processed_messages: messages.to_owned(), }
}

///|
impl @posoco.ModelPort for RetentionModel with fn compact(
  _self,
  _scope,
  _messages,
  _tools,
  _options,
  _trigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse("RetentionModel does not compact")
}

///|
impl @posoco.ModelPort for RetentionModel with fn provider_config(_self) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
fn retention_router(
  answer~ : String,
  stream~ : Bool = false,
  http_probe~ : Bool = false,
  http_probe_port~ : Int32 = 0,
) -> @ext_llm.RouterModelPort {
  let port : &@posoco.ModelPort = {
    answer,
    count: Ref(0),
    stream,
    http_probe,
    http_probe_port,
  }
  let slot = @ext_llm.ModelSlot::ModelSlot(
    id="main",
    label="main",
    provider_id="probe",
    model_id="probe-model",
    port~,
  )
  @ext_llm.RouterModelPort(slots=[slot]) catch {
    error => abort("retention router: " + error.to_string())
  }
}

///|
/// One POST whose body mirrors the conversation's total content size, whole
/// response read, connection closed. No SSE parsing, no per-line reads.
async fn retention_http_probe_post(
  url : String,
  body_chars : Int32,
) -> Int32 raise @posoco.ModelError {
  let filler = "0123456789abcdef ghij ".repeat(body_chars / 23 + 1)[:body_chars].to_owned()
  let client = @http.post(url, headers={}) catch {
    err => raise @posoco.ModelError::Transport("http probe post: \{err}")
  }
  defer client.close()
  client.write(@utf8.encode(filler)[:]) catch {
    err => raise @posoco.ModelError::Transport("http probe write: \{err}")
  }
  let response = client.end_request() catch {
    err => raise @posoco.ModelError::Transport("http probe end: \{err}")
  }
  let body = client.read_all() catch {
    err => raise @posoco.ModelError::Transport("http probe read: \{err}")
  }
  ignore(response)
  body.length()
}

///|
/// One composed session driven for `turns` turns through the given router.
async fn retention_run_session(
  turns : Int32,
  router : @ext_llm.RouterModelPort,
) -> Unit {
  @async.with_task_group(group => {
    let home = @fs.tmpdir(prefix="cetas-retain-")
    let fs = @workspace.NativeWorkspaceFs()
    fs.mkdir(home + "/.cetas", recursive=true) catch {
      _ => ()
    }
    fs.write_file(
      home + "/.cetas/settings.json",
      "{\"providers\":{\"opencode\":{\"api_key\":\"sk-fixture\"}}}",
    ) catch {
      _ => ()
    }
    let cwd = @fs.tmpdir(prefix="cetas-retain-ws-")
    let platform = @cetas_core.build_cetas_platform(
      home~,
      cwd~,
      fs,
      permission_mode=@permission.PermissionMode::Yolo,
    ) catch {
      error => abort("platform: " + error.to_string())
    }
    let session = @cetas_core.build_cetas_session(
      platform~,
      cwd~,
      router=Some(router),
      label="cetas-retain",
    ) catch {
      error => abort("session: " + error.to_string())
    }
    let agent = @cetas_core.compose_cetas_agent(session~)
    for i in 0..<turns {
      let input : @posoco.Message = @posoco.Message::UserMessage(content=[
        @posoco.Content::Text("probe turn \{i}"),
      ])
      ignore(agent.run_turn(input, "retain-session"))
      println("MARK turn \{i + 1}")
      @async.sleep(60)
    }
    println("MARK done")
    @async.sleep(200)
    ignore(group)
  })
}

///|
async test "retention probe, in-process streaming port (control)" {
  if !(retention_probe_enabled() catch { _ => false }) {
    println("SKIP: no /tmp/cetas-retain-probe-on")
    return
  }
  @async.with_task_group(group => {
    retention_run_session(
      4,
      retention_router(answer=retention_answer(24), stream=true),
    )
    ignore(group)
  })
}

///|
async test "retention probe, http custom port" {
  if !(retention_probe_enabled() catch { _ => false }) {
    println("SKIP: no /tmp/cetas-retain-probe-on")
    return
  }
  @async.with_task_group(group => {
    let port : Int32 = 8933
    let base = "http://127.0.0.1:\{port}/v1"
    let port : &@posoco.ModelPort = @custom.CustomModelPort::CustomModelPort(
      "probe",
      @custom.CustomConfig::CustomConfig(
        "k-probe",
        base_url=base,
        model="probe-model",
      ),
    )
    let slot = @ext_llm.ModelSlot::ModelSlot(
      id="main",
      label="main",
      provider_id="probe",
      model_id="probe-model",
      port~,
    )
    let router = @ext_llm.RouterModelPort(slots=[slot]) catch {
      error => abort("custom router: " + error.to_string())
    }
    retention_run_session(4, router)
    ignore(group)
  })
}

///|
async test "retention probe, raw http under composition" {
  if !(retention_probe_enabled() catch { _ => false }) {
    println("SKIP: no /tmp/cetas-retain-probe-on")
    return
  }
  @async.with_task_group(group => {
    let port : Int32 = 8933
    retention_run_session(
      4,
      retention_router(
        answer=retention_answer(24),
        http_probe=true,
        http_probe_port=port,
      ),
    )
    ignore(group)
  })
}

///|
async test "retention probe, raw http no agent" {
  if !(retention_probe_enabled() catch { _ => false }) {
    println("SKIP: no /tmp/cetas-retain-probe-on")
    return
  }
  @async.with_task_group(group => {
    let port : Int32 = 8933
    let mut block = ""
    for _ in 0..<12288 {
      block = block + "0123456789abcdef ghij "
    }
    for i in 0..<4 {
      let mut content = "turn \{i} "
      for _ in 0..<(i + 1) {
        content = content + block
      }
      try {
        let client = @http.post(
          "http://127.0.0.1:\{port}/v1/chat/completions",
          headers={},
        )
        defer client.close()
        client.write(@utf8.encode(content)[:]) catch {
          err => abort("write: \{err}")
        }
        let response = client.end_request() catch {
          err => abort("end: \{err}")
        }
        ignore(response)
        ignore(client.read_all())
      } catch {
        err => abort("post \{i}: \{err}")
      }
      println("MARK raw \{i + 1}")
      @async.sleep(60)
    }
    println("MARK raw done")
    @async.sleep(150)
    ignore(group)
  })
}
