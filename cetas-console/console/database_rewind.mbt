///|
fn database_user_text(message : @kernel.Message) -> String? {
  match message {
    @kernel.Message::UserMessage(content~) => {
      let pieces : Array[String] = []
      let mut has_image = false
      for item in content {
        match item {
          @kernel.Content::Text(text) => pieces.push(text)
          @kernel.Content::Image(..) => has_image = true
        }
      }
      let text = pieces.join("\n")
      if text.is_empty() && !has_image {
        None
      } else {
        let trimmed = text.trim_start()
        if trimmed.has_prefix("## Memory") ||
          (trimmed.has_prefix("<") && trimmed.has_prefix("<context")) {
          None
        } else {
          Some(text)
        }
      }
    }
    _ => None
  }
}

///|
async fn database_rewind_points(
  catalog : &SessionCatalog,
  id : String,
) -> Json {
  let session = catalog.load(id) catch {
    error => return rewind_error(error.to_string())
  }
  let points : Array[Json] = []
  for index in 0..<session.messages.length() {
    let message = session.messages[index]
    match database_user_text(message) {
      Some(text) => {
        let preview = @devkit.truncate_chars(text.trim().to_owned(), 60)
        if !preview.is_empty() {
          points.push(Json::object({
            "message_index": Json::number(index.to_double()),
            "preview": Json::string(preview),
          }))
        } else {
          points.push(Json::object({
            "message_index": Json::number(index.to_double()),
            "preview": Json::string("(image)"),
          }))
        }
      }
      None => ()
    }
  }
  Json::object({ "points": Json::array(points) })
}

///|
async fn database_rewind_user_message(
  catalog : &SessionCatalog,
  id : String,
  index : Int32,
) -> String? {
  if index < 0 {
    return None
  }
  let session = catalog.load(id) catch { _ => return None }
  if index >= session.messages.length() {
    return None
  }
  database_user_text(session.messages[index])
}
