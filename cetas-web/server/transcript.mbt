///|
/// One replayed tool call whose result is patched in when its ToolMessage
/// arrives later in the transcript.
struct ReplayTool {
  turn_id : String
  call_id : String
  name : String
  args : Json
  item_index : Int
  mut status : String
  mut result : String
}

///|
fn content_text(contents : Array[@kernel.Content]) -> String {
  let builder = StringBuilder()
  let mut first = true
  for content in contents {
    match content {
      @kernel.Content::Text(text) => {
        if first {
          first = false
        } else {
          builder.write_char('\n')
        }
        builder.write_string(text)
      }
      _ => ()
    }
  }
  builder.to_string()
}

///|
fn replay_tool_json(tool : ReplayTool) -> Json {
  Json::object(
    Map::from_array([
      ("kind", Json::string("tool")),
      ("turnId", Json::string(tool.turn_id)),
      ("callId", Json::string(tool.call_id)),
      ("name", Json::string(tool.name)),
      ("status", Json::string(tool.status)),
      ("args", tool.args),
      ("result", Json::string(tool.result)),
    ]),
  )
}

///|
fn transcript_empty_json() -> Json {
  Json::object(Map::from_array([("items", Json::array([]))]))
}

///|
/// Project a persisted session into the exact item shapes the web transcript
/// renders live, so replay and streaming share one rendering path.
fn transcript_json(session : @posoco_types.Session) -> Json {
  let items : Array[Json] = []
  let tools : Array[ReplayTool] = []
  let tool_index : Map[String, Int] = Map([])
  let mut message_index = 0
  for message in session.messages {
    let turn_id = "r-" + message_index.to_string()
    match message {
      @kernel.Message::SystemMessage(..) => ()
      @kernel.Message::UserMessage(content~) => {
        let text = content_text(content)
        if text != "" {
          items.push(
            Json::object(
              Map::from_array([
                ("kind", Json::string("user")),
                ("turnId", Json::string(turn_id)),
                ("text", Json::string(text)),
              ]),
            ),
          )
        }
      }
      @kernel.Message::AssistantMessage(content~, tool_calls~, reasoning~, ..) => {
        match reasoning {
          Some(reasoning) =>
            if reasoning.content != "" {
              items.push(
                Json::object(
                  Map::from_array([
                    ("kind", Json::string("reasoning")),
                    ("turnId", Json::string(turn_id)),
                    ("text", Json::string(reasoning.content)),
                    ("streaming", Json::boolean(false)),
                  ]),
                ),
              )
            }
          None => ()
        }
        let text = content_text(content)
        if text != "" {
          items.push(
            Json::object(
              Map::from_array([
                ("kind", Json::string("assistant")),
                ("turnId", Json::string(turn_id)),
                ("text", Json::string(text)),
                ("streaming", Json::boolean(false)),
              ]),
            ),
          )
        }
        for call in tool_calls {
          let call_id = call.call_id.to_string()
          tool_index[call_id] = tools.length()
          let tool : ReplayTool = {
            turn_id,
            call_id,
            name: call.name.to_string(),
            args: call.arguments,
            item_index: items.length(),
            status: "running",
            result: "",
          }
          tools.push(tool)
          items.push(replay_tool_json(tool))
        }
      }
      @kernel.Message::ToolMessage(call_id~, outcome~, ..) =>
        match tool_index.get(call_id.to_string()) {
          Some(index) => {
            let tool = tools[index]
            match outcome {
              @kernel.ToolOutcome::Success(content~, ..) => {
                tool.status = "done"
                tool.result = content
              }
              @kernel.ToolOutcome::SuccessWithAttachments(content~, ..) => {
                tool.status = "done"
                tool.result = content
              }
              @kernel.ToolOutcome::ToolReportedError(content~, ..) => {
                tool.status = "error"
                tool.result = content
              }
              @kernel.ToolOutcome::RuntimeFailure(..) as outcome => {
                tool.status = "error"
                tool.result = outcome.to_string()
              }
              @kernel.ToolOutcome::NotExecuted(reason~, ..) => {
                tool.status = "error"
                tool.result = "not executed: \{@debug.to_string(reason)}"
              }
            }
            items[tool.item_index] = replay_tool_json(tool)
          }
          None => ()
        }
    }
    message_index += 1
  }
  Json::object(Map::from_array([("items", Json::array(items))]))
}
