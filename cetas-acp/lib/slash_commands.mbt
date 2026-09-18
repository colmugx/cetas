///|
/// slash_commands.mbt — pre-turn interception of the host's `/name`
/// command. The prompt's first Text block names the command and the
/// remaining text is its positional argument; the turn is answered locally
/// without the model. Text no registered command claims reaches the model
/// untouched.

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
/// Run the host's `/name` command instead of a model turn: retitle the
/// session's persisted record, then push the new title so the client can
/// save it with its own conversation record. Failure surfaces the reason as
/// a `user_message_chunk` (the one client-visible channel available here —
/// no new protocol is invented, an undeliverable message is dropped).
/// Returns `None` when the line names no registered command, leaving the
/// prompt for the model.
async fn dispatch_slash_command(
  session_id~ : String,
  handle : SessionHandle,
  prompt~ : Array[@acp.ContentBlock],
) -> @acp.PromptResult? noraise {
  let (name, args) = match slash_command_of(prompt) {
    Some(parts) => parts
    None => return None
  }
  if name != "name" {
    return None
  }
  match slash_name_argument(args) {
    Err(reason) => push_slash_feedback(handle, session_id, reason)
    Ok(title) =>
      match rename_session(handle.store, session_id, title) {
        Ok(_) =>
          // The rename is on disk; the client learns the new title by push.
          push_session_title(session_id, handle, only_unnamed=false)
        Err(reason) => push_slash_feedback(handle, session_id, reason)
      }
  }
  Some({ stop_reason: EndTurn, meta: Omitted, })
}

///|
/// Rename the session's persisted record; a session with nothing committed
/// yet has no record for the name to ride on.
async fn rename_session(
  store : @fs_session.JsonlSessionStore,
  session_id : String,
  title : String,
) -> Result[Unit, String] noraise {
  let committed : Result[@posoco.Session, Error] = Ok(store.load(session_id)) catch {
    error => Err(error)
  }
  match committed {
    Ok(session) =>
      if session.messages.is_empty() {
        Err("no session history to rename yet")
      } else {
        let renamed : Result[Unit, Error] = Ok(
          store.set_session_name(session_id, title),
        ) catch {
          error => Err(error)
        }
        match renamed {
          Ok(_) => Ok(())
          Err(error) => Err("rename failed: " + error.to_string())
        }
      }
    Err(error) => Err("rename failed: " + error.to_string())
  }
}

///|
/// The `/name` positional argument: non-empty after trimming. Slash
/// frontends hand the raw remainder, so the whole argument is the title.
fn slash_name_argument(args : String) -> Result[String, String] {
  let trimmed = args.trim(chars=" \t")
  if trimmed.length() == 0 {
    Err("usage: /name <non-empty title>")
  } else {
    Ok(trimmed.to_owned())
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
