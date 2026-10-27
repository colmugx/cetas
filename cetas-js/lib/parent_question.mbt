///|
/// Host-glue adapter between the two question extensions: implements the
/// ask-question extension's endpoint contract by delegating to the subagent
/// extension's parent channel. This file is the ONLY place the two meet —
/// the extensions themselves never import each other.

///|
/// Endpoint bound to one child session: `ask_question_child` calls in that
/// child park on the parent agent's question broker until answered.
priv struct CetasParentQuestionEndpoint {
  channel : @subagent.ParentQuestionChannel
  child_session : String
}

///|
fn CetasParentQuestionEndpoint::CetasParentQuestionEndpoint(
  channel~ : @subagent.ParentQuestionChannel,
  child_session~ : String,
) -> CetasParentQuestionEndpoint {
  { channel, child_session, }
}

///|
impl @askquestion.QuestionEndpoint for CetasParentQuestionEndpoint with fn request(
  self : CetasParentQuestionEndpoint,
  origin_call~ : String,
  req~ : @posoco.UiRequest,
) -> @posoco.UiResponse raise @askquestion.QuestionError {
  self.channel.ask(child_session=self.child_session, origin_call~, req~) catch {
    @subagent.QuestionError::Unsupported(detail) =>
      raise @askquestion.QuestionError::Unsupported(detail)
    @subagent.QuestionError::Cancelled =>
      raise @askquestion.QuestionError::Cancelled
    @subagent.QuestionError::TimedOut =>
      raise @askquestion.QuestionError::TimedOut
    @subagent.QuestionError::Io(detail) =>
      raise @askquestion.QuestionError::Io(detail)
  }
}

///|
impl @askquestion.QuestionEndpoint for CetasParentQuestionEndpoint with fn request_with_audience(
  self : CetasParentQuestionEndpoint,
  origin_call~ : String,
  audience~ : String,
  req~ : @posoco.UiRequest,
) -> @posoco.UiResponse raise @askquestion.QuestionError {
  let _ = audience
  self.channel.ask(child_session=self.child_session, origin_call~, req~) catch {
    @subagent.QuestionError::Unsupported(detail) =>
      raise @askquestion.QuestionError::Unsupported(detail)
    @subagent.QuestionError::Cancelled =>
      raise @askquestion.QuestionError::Cancelled
    @subagent.QuestionError::TimedOut =>
      raise @askquestion.QuestionError::TimedOut
    @subagent.QuestionError::Io(detail) =>
      raise @askquestion.QuestionError::Io(detail)
  }
}
