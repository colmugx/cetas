///|
/// /help — deterministic quick reference that spends no model turn. The
/// command lists where the real manuals live and the host's own key
/// conventions; the full command list stays with the host's live autocomplete
/// because extension sets differ per composition.
pub impl @posoco.CommandPort for Forme with fn commands(_self : Forme) -> Array[
  @posoco.CommandDef,
] {
  [
    @posoco.CommandDef::{
      id: "help",
      label: "Help",
      description: "What cetas is and where its manuals live",
      category: "help",
      ctype: @posoco.CommandType::Action,
      params: [],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
  ]
}

///|
pub impl @posoco.CommandPort for Forme with fn invoke(
  self : Forme,
  id : String,
  _args : Json,
) -> @posoco.CommandOutcome {
  match id {
    "help" => {
      let b = StringBuilder()
      b.write_string(
        "cetas is a coding agent: it reads, edits, and searches your workspace, runs commands, and explains what it did.\n\n",
      )
      b.write_string(
        "Ask me directly for details — say \"what can you do\" or \"how do I ...\" and I will load the matching manual (cetas-about, cetas-usage, cetas-config).\n",
      )
      match self.host_note {
        Some(note) => b.write_string("\n" + note + "\n")
        None => ()
      }
      b.write_string("\nType / to browse all available commands.")
      @posoco.CommandOutcome::Success(
        feedback=b.to_string(),
        structured=None,
        ui_hint=Some(@posoco.UiHint::None),
      )
    }
    other => @posoco.CommandOutcome::Failure(reason="unknown command: " + other)
  }
}
