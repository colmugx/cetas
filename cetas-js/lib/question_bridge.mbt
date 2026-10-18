///|
/// Host glue for `notify_user` (non-blocking asks). The extension owns the
/// question table and the model-facing envelopes; cetas-js owns display and
/// answer routing. This file is the only place the two meet.
///
/// Wire shapes (TypeScript side: `src/events.ts` / `question-activity.ts`):
///
/// ```
/// { "type": "question_event", "label": "question_asked",
///   "data": { question_id, short_id, origin_call, question, kind,
///             options, asked_at, deadline_at } }
/// { "type": "question_event", "label": "question_answered",
///   "data": { question_id } }
/// ```
///
/// `notify_user` is also an ordinary tool call, so its row (args + receipt
/// content lines `question_id:` / `short_id:`) is the durable transcript
/// record the UI rebuilds from on replay; these events only carry live
/// state.

///|
/// Project one extension question event onto the host wire envelope.
pub fn question_event_to_json(event : @askquestion.QuestionEvent) -> Json {
  let (label, data) = match event {
    @askquestion.QuestionEvent::Asked(question~) => {
      let options : Array[Json] = []
      for option in question.options() {
        options.push(Json::string(option))
      }
      (
        "question_asked",
        Json::object(
          Map::from_array([
            ("question_id", Json::string(question.id)),
            ("short_id", Json::string("@" + question.short_id())),
            ("origin_call", Json::string(question.origin_call)),
            ("question", Json::string(question.prompt())),
            ("kind", Json::string(question.type_word())),
            ("options", Json::array(options)),
            ("asked_at", Json::number(question.asked_at.to_double())),
            ("deadline_at", Json::number(question.deadline_at.to_double())),
          ]),
        ),
      )
    }
    @askquestion.QuestionEvent::Answered(question_id~) =>
      (
        "question_answered",
        Json::object(
          Map::from_array([("question_id", Json::string(question_id))]),
        ),
      )
    @askquestion.QuestionEvent::Closed(question_id~) =>
      (
        "question_closed",
        Json::object(
          Map::from_array([("question_id", Json::string(question_id))]),
        ),
      )
  }
  Json::object(
    Map::from_array([
      ("type", Json::string("question_event")),
      ("label", Json::string(label)),
      ("data", data),
    ]),
  )
}

///|
/// Parse the host's answer payload: exactly one of `text` / `confirm` /
/// `index`, the same shape the model-facing `answer_question` tool takes.
fn parse_answer_response(
  response_json : String,
) -> Result[@posoco.UiResponse, String] {
  let parsed : Json = @json.parse(response_json) catch {
    _ => return Err("answer payload must be JSON")
  }
  let fields = match parsed {
    Json::Object(fields) => fields
    _ => return Err("answer payload must be a JSON object")
  }
  let text = match fields.get("text") {
    None => None
    Some(Json::String(value)) => Some(value)
    Some(_) => return Err("'text' must be a string")
  }
  let confirm = match fields.get("confirm") {
    None => None
    Some(Json::True) => Some(true)
    Some(Json::False) => Some(false)
    Some(_) => return Err("'confirm' must be a boolean")
  }
  let index = match fields.get("index") {
    None => None
    Some(Json::Number(value, ..)) => Some(value.to_int())
    Some(_) => return Err("'index' must be an integer")
  }
  let provided = [text is Some(_), confirm is Some(_), index is Some(_)]
    .filter(fn(present) { present })
    .length()
  if provided != 1 {
    return Err("provide exactly one of 'text', 'confirm', or 'index'")
  }
  match (text, confirm, index) {
    (Some(value), _, _) => Ok(@posoco.UiResponse::Text(value))
    (_, Some(value), _) =>
      if value {
        Ok(@posoco.UiResponse::Yes)
      } else {
        Ok(@posoco.UiResponse::No)
      }
    (_, _, Some(value)) => Ok(@posoco.UiResponse::Selected(value))
    _ => Err("no answer field provided")
  }
}

///|
/// Resolve one non-blocking question with the human's answer. Returns a
/// structured envelope so the host never matches on error text:
/// `{"ok":true}` on acceptance, `{"ok":false,"reason":"…"}` when the
/// question is unknown, already answered, expired, or answered with the
/// wrong kind. Acceptance means the next model call carries the
/// `[question-reply …]` envelope; the host submits the human's answer as a
/// normal user message so a turn exists to carry it.
pub fn cetas_js_answer_question(
  handle : CetasJsAgent,
  question_id : String,
  response_json : String,
) -> String {
  let response = match parse_answer_response(response_json) {
    Ok(response) => response
    Err(reason) =>
      return Json::object(
        Map::from_array([
          ("ok", Json::boolean(false)),
          ("reason", Json::string(reason)),
        ]),
      ).stringify()
  }
  let outcome = handle.askquestion.answer_async(question_id~, response~)
  match outcome {
    Ok(_) =>
      Json::object(Map::from_array([("ok", Json::boolean(true))])).stringify()
    Err(error) =>
      Json::object(
        Map::from_array([
          ("ok", Json::boolean(false)),
          ("reason", Json::string(error.to_string())),
        ]),
      ).stringify()
  }
}

///|
/// The user sent a plain reply — typed normally, no question addressing.
/// Close every open question so no expiry line is injected later; the
/// model pairs the reply with its own question from context. Returns
/// `{"ok":true,"closed":N}`. Infallible: a display-state sync must never
/// break input admission.
pub fn cetas_js_user_replied(handle : CetasJsAgent) -> String {
  let closed = handle.askquestion.close_open_for_reply()
  Json::object(
    Map::from_array([
      ("ok", Json::boolean(true)),
      ("closed", Json::number(closed.length().to_double())),
    ]),
  ).stringify()
}
