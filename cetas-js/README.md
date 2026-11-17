# Cetas JS

The JS host composes Cetas through Posoco extensions.



## PStack workflow (built-in)

All Cetas surfaces ship PStack through `posoco-ext-pstack`, with no
`CETAS_PSTACK_ASSETS_ROOT`, extra installation or activation configuration.
Run `/poteto-mode` to load the task-specific original PStack workflow;
run it again to clear the mode's session status. PStack's embedded readonly
resources are available through `read_skill_resource` on JS, Native, ACP and Run.

The extension shares Cetas's normal Skills runtime and Forme manuals, not a
second `activate_skill` ToolProvider. It uses the composed Agent's event
bus for its statusbar segment. Subagent skill access remains restricted by
Kind selection. Toggling off cannot erase already loaded conversation history.
No Cursor automations, cloud agents or other peripheral features are included.
