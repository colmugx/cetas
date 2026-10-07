///|
/// One capability entry under a role section: `label` is the h3 line,
/// `detail` the muted description after it.
fn zoo_item(label : String, detail : String) -> Json {
  Json::object(
    Map::from_array([
      ("label", Json::string(label)),
      ("detail", if detail == "" { Json::null() } else { Json::string(detail) }),
    ]),
  )
}

///|
fn zoo_role(role : String, items : Array[Json], count : Int) -> Json {
  Json::object(
    Map::from_array([
      ("role", Json::string(role)),
      ("count", Json::number(count.to_double())),
      ("items", Json::array(items)),
    ]),
  )
}

///|
/// Ext zoo: a live projection of every extension composed into the agent —
/// collected from the session's real manifests, so the zoo always reflects
/// what actually runs, not what the recipe declares. Every port role the
/// manifest populates gets a section; content under each section comes only
/// from that port's own contract (ToolDef, CommandDef,
/// SystemPromptContributor, UiDescriptor) — never ext internals.
fn ext_zoo_entries(exts : Array[&@posoco.Extension]) -> Array[Json] {
  let entries : Array[Json] = []
  let seen : Map[String, Unit] = Map([])
  for ext in exts {
    let manifest = ext.manifest()
    let id = manifest.id
    if seen.contains(id) {
      continue
    }
    seen[id] = ()
    let roles : Array[Json] = []

    let tools : Array[Json] = []
    for provider in manifest.tools {
      for def in provider.list_tools() {
        tools.push(zoo_item(def.name.to_string(), def.description))
      }
    }
    if manifest.tools.length() > 0 {
      roles.push(zoo_role("tools", tools, tools.length()))
    }

    let commands : Array[Json] = []
    for port in manifest.commands {
      for command in port.commands() {
        let detail = if command.description != command.label {
          command.description
        } else {
          ""
        }
        commands.push(zoo_item("/" + command.id, detail))
      }
    }
    if manifest.commands.length() > 0 {
      roles.push(zoo_role("commands", commands, commands.length()))
    }

    if manifest.prompt_contributors.length() > 0 {
      let prompts : Array[Json] = []
      for contributor in manifest.prompt_contributors {
        let prompt = contributor.system_prompt()
        prompts.push(
          zoo_item("system prompt", "\{prompt.length()} chars contributed"),
        )
      }
      roles.push(zoo_role("prompt_contributors", prompts, prompts.length()))
    }

    if manifest.ui.length() > 0 {
      let sources : Array[Json] = []
      for ui in manifest.ui {
        let descriptor = ui.ui_descriptor()
        for source in descriptor.autocomplete_sources {
          sources.push(zoo_item(source.trigger + " (" + source.kind + ")", ""))
        }
      }
      roles.push(zoo_role("ui", sources, manifest.ui.length()))
    }

    let counted : Array[(String, Int)] = [
      ("models", manifest.models.length()),
      ("decisions", manifest.decisions.length()),
      ("logs", manifest.logs.length()),
      ("sessions", manifest.sessions.length()),
      ("observers", manifest.observers.length()),
      ("hooks", manifest.hooks.length()),
      ("memory", manifest.memory.length()),
      ("lifecycle", manifest.lifecycle.length()),
    ]
    for pair in counted {
      let (role, count) = pair
      if count > 0 {
        roles.push(zoo_role(role, [], count))
      }
    }

    entries.push(
      Json::object(
        Map::from_array([
          ("id", Json::string(id)),
          ("roles", Json::array(roles)),
        ]),
      ),
    )
  }
  entries
}
