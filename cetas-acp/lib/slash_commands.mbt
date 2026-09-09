///|
/// slash_commands.mbt — pre-turn interception of the commands the session
/// store registers (`/name …`). The prompt's first Text block names the
/// command and the remaining text is its positional argument; the turn is
/// answered locally without the model. Text no registered command claims
/// reaches the model untouched.

///|
/// Split the prompt's first Text block into (command id, argument text) when
/// the trimmed line starts with `/`; the argument keeps its inner spacing.
/// `None` when the prompt has no text block or the line is not a command.
fn slash_command_of(prompt : Array[@acp.ContentBlock]) -> (String, String)? {
  let mut text : String? = None
  for block in prompt {
    match block {
      Text({ text: candidate, .. }) => {
        text = Some(candidate)
        break
      }
      _ => ()
    }
  }
  let raw = match text {
    Some(raw) => raw
    None => return None
  }
  let trimmed = raw.trim()
  if !trimmed.has_prefix("/") {
    return None
  }
  let body = trimmed[1:].to_owned()
  let name = StringBuilder()
  let mut cut = body.length()
  let mut index = 0
  for ch in body {
    if ch is (' ' | '\t' | '\n' | '\r') {
      cut = index
      break
    }
    name.write_char(ch)
    index += 1
  }
  let args = if cut < body.length() { body[cut + 1:].to_owned() } else { "" }
  Some((name.to_string(), args))
}

///|
/// Run a matched store command instead of a model turn: success pushes the
/// fresh title, failure surfaces the reason as a `user_message_chunk` (the
/// one client-visible channel available here — no new protocol is invented,
/// an undeliverable message is dropped). Returns `None` when no registered
/// command matches, leaving the prompt for the model.
async fn dispatch_slash_command(
  session_id~ : String,
  handle : SessionHandle,
  prompt~ : Array[@acp.ContentBlock],
) -> @acp.PromptResult? noraise {
  let (name, args) = match slash_command_of(prompt) {
    Some(parts) => parts
    None => return None
  }
  let port : &@posoco.CommandPort = handle.store as &@posoco.CommandPort
  let mut matched = false
  for def in port.commands() {
    if def.id == name {
      matched = true
      let outcome : Result[@posoco.CommandOutcome, Error] = Ok(
        port.invoke(def.id, Json::string(args)),
      ) catch {
        error => Err(error)
      }
      match outcome {
        Ok(@posoco.CommandOutcome::Success(..)) =>
          // The rename is on disk; the client learns the new title by push.
          push_session_title(session_id, handle, only_unnamed=false)
        Ok(@posoco.CommandOutcome::Failure(reason~)) =>
          push_slash_feedback(handle, session_id, reason)
        Ok(@posoco.CommandOutcome::NeedsInput(..)) => ()
        Err(_) => ()
      }
    }
  }
  if matched {
    Some({ stop_reason: EndTurn, meta: Omitted, })
  } else {
    None
  }
}

///|
/// Best-effort delivery of a slash command's failure reason as a
/// user-message chunk; without an attached context it is dropped.
async fn push_slash_feedback(
  handle : SessionHandle,
  session_id : String,
  text : String,
) -> Unit noraise {
  match handle.context {
    Some(context) =>
      context.session_update({
        session_id,
        update: @acp.SessionUpdate::UserMessageChunk({
          content: Text({ annotations: Omitted, text, meta: Omitted, }),
          message_id: Omitted,
          meta: Omitted,
        }),
        meta: Omitted,
      }) catch {
        _ => ()
      }
    None => ()
  }
}
