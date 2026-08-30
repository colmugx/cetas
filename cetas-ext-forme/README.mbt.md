# cetas-ext-forme

Cetas self-description extension for [Posoco](https://mooncakes.io/docs/colmugx/posoco).

Cetas answers "what are you / how do I use you / how are you configured" from
a manual that ships with the product instead of the model's memory of it.
`Forme` contributes two surfaces over one struct: a `/help` command
(deterministic quick reference, no model turn) and a system-prompt routing
note that steers capability, usage, and configuration questions to the
built-in manual skills first. The manuals themselves are inline
`SkillDescriptor`s — `builtin_manual_skills()` returns three
(`cetas-about`, `cetas-usage`, `cetas-config`) whose instructions are
compiled into the binary. cetas-core merges them into its single skills
extension with `@skills.merge_builtin_skills`, so the manuals ride the
normal `activate_skill` progressive-disclosure path: only name and
description enter the startup prompt; activation returns the full text
without touching the filesystem, and `read_skill_resource` fails closed
for built-ins. Users never see or manage any file for this.

```moonbit nocheck
// cetas-core wiring (build_default_features):
let builtin_manuals = @forme.builtin_manual_skills()
let catalog = @skills.merge_builtin_skills(discovered_catalog, builtin_manuals)
let skills = @skills.Skills::from_catalog(fs, catalog~, config~)
exts.push(@forme.Forme::Forme(host_note=host_help_note) as &@posoco.Extension)
```

## Ports contributed

One `Forme` struct implements three public Posoco ports:

| Port | Behavior |
| --- | --- |
| `CommandPort` | `help` (Action): returns a short product introduction, pointers to the three manual skills, the host note (if any), and "type / to browse all available commands". Unknown ids fail closed. |
| `SystemPromptContributor` | One routing sentence: activate the matching `cetas-*` manual before answering capability/usage/config questions; answer from the activated manual, not memory. |
| `Extension` | id `forme`; manifest fills `commands: [self]` and `prompt_contributors: [self]`. |

The `host_note~` constructor argument carries host-specific keybinding and
input conventions into `/help` output (cetas-js passes its TUI keys; hosts
without a UI omit it). Command-list rendering stays with the host's live
autocomplete because extension sets differ per composition.
