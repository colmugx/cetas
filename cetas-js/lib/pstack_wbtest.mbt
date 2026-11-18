///|
/// The default recipe registers the embedded PStack bundle as one Skills
/// runtime: the `$poteto-mode` entry point, its explicit-activation hook, and
/// the bundled playbooks reachable through the activated skill without any
/// assets directory.
async test "pstack: default recipe composes the poteto-mode entry point" {
  let fs = @workspace.JsWorkspaceFs()
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
  for port in manifest.commands {
    for def in port.commands() {
      commands.push(def.id)
    }
  }
  // Skills' `skills` command only: the workflow is entered with the
  // `$poteto-mode` mention, not a pstack-owned command.
  assert_eq(commands, ["skills"])
  // Skills' explicit-mention hook plus PStack's activation observer.
  assert_eq(manifest.hooks.length(), 2)
}
