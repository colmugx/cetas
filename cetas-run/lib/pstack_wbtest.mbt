///|
/// The default recipe registers the embedded PStack bundle as one Skills
/// runtime: both commands, the native toggle, and the bundled playbooks
/// reachable through the activated skill without any assets directory.
async test "pstack: default recipe composes native toggle and skills" {
  let fs = @workspace.NativeWorkspaceFs()
  let ext = build_cetas_skills(
    ctx={ fs, cwd: ".", home: ".", },
    manuals=@forme.Forme::Forme().builtin_manual_skills(),
  ).unwrap()
  assert_eq(ext.extension_id(), "posoco_ext_pstack")
  let manifest = ext.manifest()
  assert_eq(manifest.tools.length(), 1)
  let names : Array[String] = []
  for provider in manifest.tools {
    for def in provider.list_tools() {
      names.push(def.name.to_string())
    }
  }
  assert_true(names.contains("activate_skill"))
  assert_true(names.contains("read_skill_resource"))
  assert_eq(names.length(), 3)
  let commands : Array[String] = []
  let mut toggle : &@posoco.CommandPort? = None
  for port in manifest.commands {
    for def in port.commands() {
      commands.push(def.id)
      if def.id == "poteto-mode" {
        toggle = Some(port)
      }
    }
  }
  assert_true(commands.contains("skills"))
  assert_true(commands.contains("poteto-mode"))
  match toggle {
    Some(port) => {
      match port.invoke("poteto-mode", Json::null()) {
        @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
          assert_true(feedback.contains("activated skill: poteto-mode"))
          assert_true(
            structured.unwrap().stringify().contains("agent_skill_activation"),
          )
        }
        _ => fail("PStack activation failed")
      }
      match port.invoke("poteto-mode", Json::null()) {
        @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
          assert_true(feedback.contains("Mode Off"))
          assert_true(structured is None)
        }
        _ => fail("PStack toggle off failed")
      }
    }
    None => fail("PStack command was not registered")
  }
}
