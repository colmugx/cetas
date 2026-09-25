// E2E: the context contributor's self-describing <cetas-context> envelope
// reaches the model's SystemMessage without an extra model-visible label.

///|
async test "e2e: Cetas keeps project context envelope self-describing" {
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
  // Cetas owns identity + prompt assembly. This test only exercises prompt
  // assembly.
  let cetas = Cetas(
    context_contributor=Some(
      context_contributor as &@posoco.SystemPromptContributor,
    ),
  )
  // Compose exactly the way a host does: every part is an Extension.
  // Test fakes (store / observer / ui / scripted model) are not Extensions
  // yet — posoco reform is deferred; wrap via ManifestOnly for this test.
  let agent = @posoco.Agent(
    exts=[
      cetas,
      @posoco.ManifestOnly::ManifestOnly(
        @posoco.ExtensionManifest(id="model", models=[
          model as &@posoco.ModelPort,
        ]),
      ),
      @posoco.ManifestOnly::ManifestOnly(
        @posoco.ExtensionManifest(id="store", sessions=[
          store as &@posoco.SessionStore,
        ]),
      ),
      @posoco.ManifestOnly::ManifestOnly(
        @posoco.ExtensionManifest(id="observer", observers=[
          observer as &@posoco.Observer,
        ]),
      ),
      @posoco.ManifestOnly::ManifestOnly(
        @posoco.ExtensionManifest(id="ui", ui=[ui as &@posoco.UiPort]),
      ),
    ],
    config=@posoco.agent_config(
      max_tool_rounds=Some(5),
      system_prompt=Some(cetas_system_prompt(cwd="/repo")),
    ),
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
          // No redundant model-visible wrapper is needed around the envelope.
          assert_false(t.contains("project_context:\n"))
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
    context_contributor=Some(
      context_contributor as &@posoco.SystemPromptContributor,
    ),
  )
  let ext_contributor : &@posoco.SystemPromptContributor = FakeExtContributor::{
    text: "EXT_SECTION",
  }
  let agent = @posoco.Agent(
    exts=[
      cetas,
      @posoco.ManifestOnly::ManifestOnly(
        @posoco.ExtensionManifest(id="ext", prompt_contributors=[
          ext_contributor,
        ]),
      ),
      @posoco.ManifestOnly::ManifestOnly(
        @posoco.ExtensionManifest(id="model", models=[
          model as &@posoco.ModelPort,
        ]),
      ),
      @posoco.ManifestOnly::ManifestOnly(
        @posoco.ExtensionManifest(id="store", sessions=[
          store as &@posoco.SessionStore,
        ]),
      ),
      @posoco.ManifestOnly::ManifestOnly(
        @posoco.ExtensionManifest(id="observer", observers=[
          observer as &@posoco.Observer,
        ]),
      ),
      @posoco.ManifestOnly::ManifestOnly(
        @posoco.ExtensionManifest(id="ui", ui=[ui as &@posoco.UiPort]),
      ),
    ],
    config=@posoco.agent_config(
      max_tool_rounds=Some(5),
      system_prompt=Some(cetas_system_prompt(cwd="/repo")),
    ),
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
          // The context envelope and later extension contribution both survive.
          assert_false(t.contains("project_context:\n"))
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
