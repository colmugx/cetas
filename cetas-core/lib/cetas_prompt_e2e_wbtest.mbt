// E2E: the context contributor gets section id "project_context" (not Agent's
// generic "section_0"); its <cetas-context> envelope must reach the model's
// SystemMessage. cetas-core owns the section labeling for context vs tool guidance.

///|
async test "e2e: Cetas labels context contributor as project_context" {
  // A ContextBundle with one ancestor doc. We construct it inline (cetas-core
  // does not depend on posoco-ext-context; it only consumes the
  // SystemPromptContributor trait, which ContextPromptContributor implements).
  // To avoid a cross-package dependency, we use a minimal local contributor
  // that emits the same <cetas-context> shape.
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("ok")),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let observer = @posoco.RecordingObserver::RecordingObserver()
  let ui = @posoco.NoopUiPort::NoopUiPort()
  let context_contributor = CetasContextStub::new(
    "/repo/AGENTS.md", "Build with: moon test",
  )
  // Cetas owns identity + prompt assembly + /profile. Profile callbacks are
  // stubbed; this test only exercises prompt assembly.
  let cetas = Cetas::Cetas(
    cwd="/repo",
    ui=ui as &@posoco.UiPort,
    context_contributor=Some(
      context_contributor as &@posoco.SystemPromptContributor,
    ),
    list_profiles=fn() { [] },
    on_load=fn(_name) { () },
    on_save=fn(_name) { () },
    on_delete=fn(_name) { () },
  )
  // Compose exactly the way a host does: every part is an Extension.
  // Test fakes (store / observer / ui / scripted model) are not Extensions
  // yet — posoco reform is deferred; wrap via ManifestOnly for this test.
  let agent = @posoco.Agent(
    exts=[
      cetas,
      @posoco.ManifestOnly::ManifestOnly({
        id: "model",
        models: [model as &@posoco.ModelPort],
        tools: [],
        sessions: [],
        observers: [],
        pre_model_hooks: [],
        pre_tool_hooks: [],
        post_event_hooks: [],
        memory: [],
        lifecycle: [],
        commands: [],
        ui: [],
        prompt_contributors: [],
      }),
      @posoco.ManifestOnly::ManifestOnly({
        id: "store",
        models: [],
        tools: [],
        sessions: [store as &@posoco.SessionStore],
        observers: [],
        pre_model_hooks: [],
        pre_tool_hooks: [],
        post_event_hooks: [],
        memory: [],
        lifecycle: [],
        commands: [],
        ui: [],
        prompt_contributors: [],
      }),
      @posoco.ManifestOnly::ManifestOnly({
        id: "observer",
        models: [],
        tools: [],
        sessions: [],
        observers: [observer as &@posoco.Observer],
        pre_model_hooks: [],
        pre_tool_hooks: [],
        post_event_hooks: [],
        memory: [],
        lifecycle: [],
        commands: [],
        ui: [],
        prompt_contributors: [],
      }),
      @posoco.ManifestOnly::ManifestOnly({
        id: "ui",
        models: [],
        tools: [],
        sessions: [],
        observers: [],
        pre_model_hooks: [],
        pre_tool_hooks: [],
        post_event_hooks: [],
        memory: [],
        lifecycle: [],
        commands: [],
        ui: [ui as &@posoco.UiPort],
        prompt_contributors: [],
      }),
    ],
    config={
      max_tool_rounds: 5,
      temperature: None,
      max_output_tokens: None,
      model_context_window: None,
    },
  )
  ignore(agent.run_turn(@posoco.tk_user_msg("hello"), "s1"))
  // Inspect what the model received.
  assert_true(model.received_messages.length() > 0)
  let msgs = model.received_messages[0]
  match msgs[0] {
    @posoco.Message::SystemMessage(content~) =>
      match content {
        [@posoco.Content::Text(t), ..] => {
          // The cetas base prompt (identity + envelope semantics) is present.
          assert_true(t.contains("You are Cetas"))
          assert_true(t.contains("<cetas-context>"))
          // The context contributor's envelope content landed in the prompt.
          assert_true(t.contains("<cetas-context "))
          assert_true(t.contains("source=\"/repo/AGENTS.md\""))
          assert_true(t.contains("Build with: moon test"))
          // cetas-core assigns "project_context" as the section id (not
          // Agent's generic "section_0").
          assert_true(t.contains("project_context:"))
        }
        _ => fail("system message should have text content")
      }
    _ => fail("first message should be a SystemMessage")
  }
}

///|
/// Minimal stub implementing SystemPromptContributor that emits a
/// <cetas-context> element. This mirrors ContextPromptContributor's output
/// shape without requiring cetas-core to depend on posoco-ext-context
/// (which would violate the target-agnostic constraint on this package).
struct CetasContextStub {
  source : String
  content : String
}

///|
fn CetasContextStub::new(source : String, content : String) -> CetasContextStub {
  { source, content }
}

///|
impl @posoco.SystemPromptContributor for CetasContextStub with fn system_prompt(
  self : CetasContextStub,
) -> String {
  "<cetas-context type=\"project_instructions\" trust=\"untrusted\" source=\"" +
  self.source +
  "\">\n" +
  self.content +
  "\n</cetas-context>"
}
