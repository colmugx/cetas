# Cetas JS

The JS host composes Cetas through Posoco extensions.


## Optional PStack workflow

PStack is opt-in. Set `CETAS_PSTACK_ASSETS_ROOT` to the installed
`posoco-ext-pstack/assets` directory, for example:

```sh
CETAS_PSTACK_ASSETS_ROOT="$PWD/extension/posoco-ext-pstack/assets" bun run start
```

Cetas discovers the file-backed PStack SKILL.md alongside normal project/user
Skills and Forme manuals in **one** Skills catalog. It uses the existing Posoco
tools, model, permissions and subagents. Run `/poteto-mode` to activate the
original task-specific playbooks; run it again to clear the session mode and
`🥔 Mode On` statusbar segment. The second toggle does not erase instructions
already loaded into conversation history.

An invalid configured root fails composition rather than silently falling
back to a condensed prompt. With the environment variable unset, Cetas behaves
as before, including its normal Skills command and catalog. A child Agent
reconstructs its own Skills catalog from the same directory when its Kind
allows `poteto-mode`. No Cursor cloud agents, Automations or plugins are added.
