///|
/// Injection stubs: this test only composes the ACP endpoint, so every handler
/// may answer with an empty value.
#warnings("-unused_async")
async fn resume_test_new(
  _context : @acp.AgentContext,
  _params : @acp.NewSessionParams,
) -> @acp.NewSessionResult {
  { session_id: "", modes: Omitted, config_options: Omitted, meta: Omitted, }
}

///|
#warnings("-unused_async")
async fn resume_test_prompt(
  _context : @acp.AgentContext,
  _params : @acp.PromptParams,
) -> @acp.PromptResult {
  { stop_reason: @acp.StopReason::EndTurn, meta: Omitted, }
}

///|
#warnings("-unused_async")
async fn resume_test_cancel(
  _context : @acp.AgentContext,
  _params : @acp.CancelParams,
) -> Unit {
  ()
}

///|
#warnings("-unused_async")
async fn resume_test_close(
  _context : @acp.AgentContext,
  _params : @acp.CloseSessionParams,
) -> @acp.CloseSessionResult {
  { meta: Omitted, }
}

///|
#warnings("-unused_async")
async fn resume_test_set_config_option(
  _context : @acp.AgentContext,
  _params : @acp.SetSessionConfigOptionParams,
) -> @acp.SetSessionConfigOptionResult {
  { config_options: [], meta: Omitted, }
}

///|
#warnings("-unused_async")
async fn resume_test_resume(
  _context : @acp.AgentContext,
  _params : @acp.ResumeSessionParams,
) -> @acp.ResumeSessionResult {
  { modes: Omitted, config_options: Omitted, meta: Omitted, }
}

///|
/// Memoh only calls `session/resume` when `initialize` advertised the resume
/// marker, and the marker exists only because a handler was wired. This pins
/// that contract: wiring the handler is the whole feature.
test "wiring resume advertises the capability Memoh gates on" {
  match
    @acp.agent_spec(
      info={
        name: "cetas-memoh",
        title: Value("Cetas for Memoh"),
        version: "0.0.0",
        meta: Omitted,
      },
      sessions=@acp.agent_session_service(
        new_session=resume_test_new,
        resume_session=resume_test_resume,
        prompt=resume_test_prompt,
        cancel=resume_test_cancel,
        close=resume_test_close,
        set_config_option=resume_test_set_config_option,
      ),
      support=@acp.agent_support(prompt_image=true),
    ) {
    Ok(spec) => {
      let endpoint = @acp.agent_endpoint_from_spec(spec)
      match endpoint.capabilities().session_capabilities {
        Value(session) =>
          match session.resume_capability {
            Value(_) => ()
            Omitted | Null => fail("resume marker missing from initialize")
          }
        Omitted | Null => fail("session capabilities missing from initialize")
      }
    }
    Err(_) => fail("agent spec rejected")
  }
}
