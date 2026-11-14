///|
/// Agent-backed admission for manual profile activation. The Profiles
/// CommandPort never mutates SessionStore behind the Agent's in-process
/// canonical snapshot: manual activation runs through the same turn path as
/// an ordinary user message. The host binds the Agent after composition.
pub struct CetasProfileActivationSink {
  mut agent : @posoco.Agent?
}

///|
pub fn CetasProfileActivationSink::CetasProfileActivationSink() -> CetasProfileActivationSink {
  { agent: None, }
}

///|
pub fn CetasProfileActivationSink::bind(
  self : CetasProfileActivationSink,
  agent : @posoco.Agent,
) -> Unit {
  self.agent = Some(agent)
}

///|
pub impl @profiles.ProfileActivationSink for CetasProfileActivationSink with fn submit(
  self : CetasProfileActivationSink,
  session_id : String,
  message : @posoco.Message,
) -> Result[Unit, String] {
  let agent = match self.agent {
    Some(agent) => agent
    None => return Err("profiles activation sink not bound to agent")
  }
  let submitted : Result[@posoco.TurnResult, Error] = Ok(
    agent.run_turn(message, session_id),
  ) catch {
    err => Err(err)
  }
  match submitted {
    Ok(_) => Ok(())
    Err(err) => Err(err.to_string())
  }
}

///|
pub extend CetasProfileActivationSink with @profiles.ProfileActivationSink::{
  submit,
}
