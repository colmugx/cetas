# cetas-ext-forme

Cetas self-description extension for [Posoco](https://mooncakes.io/docs/colmugx/posoco).

Cetas answers "what are you / how do I use you / how are you configured" from
a manual that ships with the product instead of the model's memory of it.
`Forme` contributes two surfaces over one struct: a `/help` command
(deterministic quick reference, no model turn) and a system-prompt routing
note that steers setup/configuration questions to the built-in manual first —
configuring cetas is forme's primary goal, usage second, identity last. The
manuals themselves are inline `SkillDescriptor`s —
`forme.builtin_manual_skills()` returns three (`cetas-config`,
`cetas-usage`, `cetas-about`) whose instructions are compiled into the
binary. Each host recipe merges them into its single skills extension with
`@skills.merge_builtin_skills`, so the manuals ride the normal
`activate_skill` progressive-disclosure path: only name and description
enter the startup prompt; activation returns the full text without touching
the filesystem, and `read_skill_resource` fails closed for built-ins. Users
never see or manage any file for this.

```moonbit nocheck
// host recipe wiring:
let forme = @forme.Forme::Forme(
  host_note=host_help_note,
  version_note=host_version_note,
)
let catalog = @skills.merge_builtin_skills(discovered_catalog, forme.builtin_manual_skills())
let skills = @skills.Skills::from_catalog(fs, catalog~, config~)
exts.push(forme as &@posoco.Extension)
```

## Ports contributed

One `Forme` struct implements three public Posoco ports:

| Port | Behavior |
| --- | --- |
| `CommandPort` | `help` (Action): states the product intro with the version line when the host provides one, pointers to the three manual skills, the host note (if any), and "type / to browse all available commands". Unknown ids fail closed. |
| `SystemPromptContributor` | One routing sentence: activate the matching `cetas-*` manual before answering; cetas-config leads because setup/configuration is the primary goal. |
| `Extension` | id `forme`; manifest fills `commands: [self]` and `prompt_contributors: [self]`. |

Two constructor arguments carry host-owned facts the manuals cannot know:

- `host_note~` — keybinding and input conventions (cetas-js passes its TUI
  keys; hosts without a UI omit it).
- `version_note~` — distribution and version line (e.g. `"0.10.9 (npm)"`),
  interpolated into `/help` and the about manual so the model states the
  running version instead of guessing. Product hosts pass it (js derives it
  from its npm/binary channel; acp and run from their version constants);
  without it the model reports the version as unknown.

The about manual lists exactly the product hosts — cetas-js, cetas-acp,
cetas-run — and instructs the model never to describe other cetas-* hosts,
which are proofs of concept. Command-list rendering stays with the host's
live autocomplete because extension sets differ per composition.
