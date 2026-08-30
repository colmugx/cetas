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
  let context_contributor = CetasContextStub(
    "/repo/AGENTS.md", "Build with: moon test",
  )
  // Cetas owns identity + prompt assembly + /profile. Profile callbacks are
  // stubbed; this test only exercises prompt assembly.
  let cetas = Cetas(
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
        hooks: [],
        memory: [],
        lifecycle: [],
        commands: [],
        ui: [],
        prompt_contributors: [],
        requires: [],
      }),
      @posoco.ManifestOnly::ManifestOnly({
        id: "store",
        models: [],
        tools: [],
        sessions: [store as &@posoco.SessionStore],
        observers: [],
        hooks: [],
        memory: [],
        lifecycle: [],
        commands: [],
        ui: [],
        prompt_contributors: [],
        requires: [],
      }),
      @posoco.ManifestOnly::ManifestOnly({
        id: "observer",
        models: [],
        tools: [],
        sessions: [],
        observers: [observer as &@posoco.Observer],
        hooks: [],
        memory: [],
        lifecycle: [],
        commands: [],
        ui: [],
        prompt_contributors: [],
        requires: [],
      }),
      @posoco.ManifestOnly::ManifestOnly({
        id: "ui",
        models: [],
        tools: [],
        sessions: [],
        observers: [],
        hooks: [],
        memory: [],
        lifecycle: [],
        commands: [],
        ui: [ui as &@posoco.UiPort],
        prompt_contributors: [],
        requires: [],
      }),
    ],
    config={
      max_tool_rounds: Some(5),
      system_prompt: Some(cetas_system_prompt(cwd="/repo")),
      temperature: None,
      max_output_tokens: None,
      model_context_window: None,
      compact_threshold: None,
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
          // Cetas labels the context contributor as the project_context section.
          assert_true(t.contains("project_context:\n"))
        }
        _ => fail("system message should have text content")
      }
    _ => fail("first message should be a SystemMessage")
  }
}

///|
/// Minimal stub implementing SystemPromptContributor that emits a
/// <cetas-context> element. Rendering goes through devkit's
/// @devkit.context_envelope — the same builder ContextPromptContributor
/// uses — without requiring cetas-core to depend on posoco-ext-context
/// (which would violate the target-agnostic constraint on this package).
struct CetasContextStub {
  source : String
  content : String
}

///|
fn CetasContextStub::CetasContextStub(
  source : String,
  content : String,
) -> CetasContextStub {
  { source, content, }
}

///|
impl @posoco.SystemPromptContributor for CetasContextStub with fn system_prompt(
  self : CetasContextStub,
) -> String {
  @devkit.context_envelope(
    ns="cetas",
    kind="project_instructions",
    trust=false,
    source=self.source,
    content=self.content,
  )
}

///|
/// Regression: the cetas base prompt and every prompt contributor from cetas
/// and from later extensions must all land in the same SystemMessage. There
/// must be no second hook that replaces it and discards the extensions'
/// contributions.
async test "e2e: base + cetas contributor + ext contributor share one SystemMessage" {
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("ok")),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let observer = @posoco.RecordingObserver::RecordingObserver()
  let ui = @posoco.NoopUiPort::NoopUiPort()
  let context_contributor = CetasContextStub(
    "/repo/AGENTS.md", "Build with: moon test",
  )
  let cetas = Cetas(
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
  let ext_contributor : &@posoco.SystemPromptContributor = FakeExtContributor::{
    text: "EXT_SECTION",
  }
  let agent = @posoco.Agent(
    exts=[
      cetas,
      @posoco.ManifestOnly::ManifestOnly({
        id: "ext",
        models: [],
        tools: [],
        sessions: [],
        observers: [],
        hooks: [],
        memory: [],
        lifecycle: [],
        commands: [],
        ui: [],
        prompt_contributors: [ext_contributor],
        requires: [],
      }),
      @posoco.ManifestOnly::ManifestOnly({
        id: "model",
        models: [model as &@posoco.ModelPort],
        tools: [],
        sessions: [],
        observers: [],
        hooks: [],
        memory: [],
        lifecycle: [],
        commands: [],
        ui: [],
        prompt_contributors: [],
        requires: [],
      }),
      @posoco.ManifestOnly::ManifestOnly({
        id: "store",
        models: [],
        tools: [],
        sessions: [store as &@posoco.SessionStore],
        observers: [],
        hooks: [],
        memory: [],
        lifecycle: [],
        commands: [],
        ui: [],
        prompt_contributors: [],
        requires: [],
      }),
      @posoco.ManifestOnly::ManifestOnly({
        id: "observer",
        models: [],
        tools: [],
        sessions: [],
        observers: [observer as &@posoco.Observer],
        hooks: [],
        memory: [],
        lifecycle: [],
        commands: [],
        ui: [],
        prompt_contributors: [],
        requires: [],
      }),
      @posoco.ManifestOnly::ManifestOnly({
        id: "ui",
        models: [],
        tools: [],
        sessions: [],
        observers: [],
        hooks: [],
        memory: [],
        lifecycle: [],
        commands: [],
        ui: [ui as &@posoco.UiPort],
        prompt_contributors: [],
        requires: [],
      }),
    ],
    config={
      max_tool_rounds: Some(5),
      system_prompt: Some(cetas_system_prompt(cwd="/repo")),
      temperature: None,
      max_output_tokens: None,
      model_context_window: None,
      compact_threshold: None,
    },
  )
  ignore(agent.run_turn(@posoco.tk_user_msg("hello"), "s1"))
  assert_true(model.received_messages.length() > 0)
  let msgs = model.received_messages[0]
  match msgs[0] {
    @posoco.Message::SystemMessage(content~) =>
      match content {
        [@posoco.Content::Text(t), ..] => {
          // Base prompt is the first section (the assembled prompt may lead
          // with whitespace from the multi-line template).
          assert_true(t.trim_start().has_prefix("You are Cetas"))
          // project_context section precedes the ext contributor section.
          assert_true(t.contains("project_context:\n"))
          assert_true(t.contains("\n\next:\nEXT_SECTION"))
          // Both contributions are actually present.
          assert_true(t.contains("Build with: moon test"))
          assert_true(t.contains("<cetas-context"))
        }
        _ => fail("system message should have text content")
      }
    _ => fail("first message should be a SystemMessage")
  }
}

///|
struct FakeExtContributor {
  text : String
}

///|
impl @posoco.SystemPromptContributor for FakeExtContributor with fn system_prompt(
  self : FakeExtContributor,
) -> String {
  self.text
}
