///|
async test "native command autocomplete and dispatch use the composed Agent catalog" {
  let model = @posoco.ScriptedModel([])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let shell = NativeShell::new()
  let forme = @forme.Forme(host_note=Some("native-test"))
  let io = @posoco.ManifestOnly::ManifestOnly(
    @posoco.ExtensionManifest(
      id="native_autocomplete_io",
      models=[model as &@posoco.ModelPort],
      sessions=[store as &@posoco.SessionStore],
    ),
  )
  let agent = @posoco.Agent(
    exts=[io as &@posoco.Extension, forme as &@posoco.Extension],
    config=@posoco.agent_config(max_tool_rounds=Some(1)),
  )
  let host = NativeHost::from_parts(
    agent,
    shell,
    store as &@posoco.SessionStore,
    "native-autocomplete",
    workspace_files=["src/", "src/main.mbt", "README.md"],
    skill_completion_items=[
      {
        value: "$cetas-usage",
        label: "$cetas-usage",
        description: "[project] usage",
      },
    ],
  )

  guard host.command_autocomplete("/he") is Some((prefix, items)) else {
    fail("expected /help completion from composed command catalog")
  }
  assert_eq(prefix, "/he")
  assert_eq(items.length(), 1)
  assert_eq(items[0].value, "/help")
  assert_true(items[0].description.contains("manuals"))

  guard host.command_autocomplete("/ses") is Some((local_prefix, local_items)) else {
    fail("expected native-local slash completion")
  }
  assert_eq(local_prefix, "/ses")
  assert_eq(local_items.length(), 1)
  assert_eq(local_items[0].value, "/sessions")

  guard host.command_autocomplete("@main") is Some((file_prefix, file_items)) else {
    fail("expected @file completion")
  }
  assert_eq(file_prefix, "@main")
  assert_eq(file_items.length(), 1)
  assert_eq(file_items[0].value, "@src/main.mbt ")

  guard host.command_autocomplete("$c") is Some((skill_prefix, skill_items)) else {
    fail("expected $skill completion")
  }
  assert_eq(skill_prefix, "$c")
  assert_eq(skill_items[0].value, "$cetas-usage")

  let outcome = host.invoke_slash_command("/help")
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, ..) => {
      assert_true(feedback.contains("cetas is a coding agent"))
      assert_true(feedback.contains("native-test"))
    }
    _ => fail("/help must dispatch through the composed command port")
  }

  let model_def = @posoco.CommandDef::{
    id: "model",
    label: "Model",
    description: "",
    category: "model",
    ctype: @posoco.CommandType::Select,
    params: [],
    aliases: [],
    shortcut: None,
    icon: None,
    visible: true,
    metadata: None,
  }
  assert_eq(
    command_args_for(model_def, "provider/model high"),
    Json::object(
      Map::from_array([
        ("slot", Json::string("provider/model")),
        ("effort", Json::string("high")),
      ]),
    ),
  )

  host.shutdown()
}
