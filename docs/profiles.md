# Profiles in Cetas

Profiles provide task-intent-driven disclosure of extension manuals. They do
**not** grant, restrict, or enable tools. Cetas retains LazyTools tool discovery
and execution for deferred extensions regardless of profile activation.

## Try a profile

Create `~/.cetas/profiles/research.json` (or
`<project>/.cetas/profiles/research.json`):

```json
{
  "id": "research",
  "name": "Research",
  "description": "For tasks requiring web research and source review",
  "exts": ["posoco_ext_webfetch"]
}
```

Restart Cetas to pick up the manifest. On a clean installation, `/profile save`
can also create the first manifest after the session has successfully used
some tools; no pre-existing manifest is required. On a matching task, the model can call
`activate_profile({"profile":"research"})` itself. That call exposes the
associated extension's manual to the **next model request in the same turn**.
It does not turn the deferred tool into a resident tool.

In the JS interactive host, the user can also invoke `/profiles research`
in an active session. Bare `/profiles` uses the normal host selector where a
UI is available. The session's own id is supplied by the JS host, not by the
user; the profile activation is admitted as an Agent turn (never a direct
session-store mutation).

To generate a profile based on the current session's observed successful tool
use, invoke `/profile save`. Cetas writes the new JSON manifest under
`~/.cetas/profiles` by default, or the project directory when the command
supplies `level:"project"`. Saving only suggests a group from usage; review
the resulting manifest before relying on it. The model-visible profile menu
is composition-static, so the new entry appears on the next Agent composition.

## Rules and limitations

- The **project** profile overrides an identically named **user** profile.
- The filename must match the manifest id, e.g. `research.json`.
- Profiles are additive for the session. There is no deactivation command.
- If no profile fits, the model should continue normally and discover tools
  through LazyTools. The builtin `all` is explicit opt-in only.
- Profile manuals are disclosed only for **episodic/deferred** extensions
  included in a profile. Resident manuals are not re-injected.
- The JS manual command has an Agent-backed activation sink; other host command
  surfaces may not expose manual activation. Model-driven activation is shared
  across the compiled host recipes.
- No profile manifests are shipped by default. With LazyTools enabled, the
  Profiles extension and `/profile save` command are available even on a clean
  installation; no deferred manuals are stripped until a manifest is authored.
  This adds the small Profiles discovery/command surface to the Agent.
