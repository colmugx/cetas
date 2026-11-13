///|
/// The Cetas composition roster: the one table binding a capability key to the
/// concrete package that fills it, per surface.
///
/// Hosts project their compiled recipe from here instead of keeping private
/// key/package literals, so a capability added for one surface cannot silently
/// miss another — the failure mode this table exists to remove. `recipes.csv`
/// remains the human-readable inventory; this is the executable copy.

///|
/// One capability entry.
///
/// `recipe` names the key the host's `build_compiled_recipe_features` switch
/// handles, `None` when the host assembles the extension at its composition
/// root instead (telemetry, presence, delegation and other non-tool ports).
/// Several packages may share one recipe key (`bash`/`ps1` both build the
/// logical `shell` capability); only one entry per key may be recipe-built.
pub(all) struct CetasCapability {
  key : String
  package_path : String
  recipe : String?
}

///|
fn capability(
  key : String,
  package_path : String,
  recipe : String?,
) -> CetasCapability {
  { key, package_path, recipe, }
}

///|
/// Frontends this roster knows. Anything else is a host that has not adopted
/// the table yet and composes nothing from it.
pub fn cetas_roster_hosts() -> Array[String] {
  ["js", "native", "acp", "run", "web"]
}

///|
/// The capabilities every Cetas surface composes. Order is the product order
/// of the compiled recipe.
pub fn cetas_shared_capabilities() -> Array[CetasCapability] {
  [
    capability("forme", "colmugx/cetas-ext-forme/lib", Some("forme")),
    capability("read", "colmugx/posoco-ext-read", Some("read")),
    capability("write", "colmugx/posoco-ext-write", Some("write")),
    capability("edit", "colmugx/posoco-ext-edit", Some("edit")),
    capability("glob", "colmugx/posoco-ext-glob", Some("glob")),
    capability("grep", "colmugx/posoco-ext-grep", Some("grep")),
    capability("astgrep", "colmugx/posoco-ext-astgrep", Some("astgrep")),
    capability("webfetch", "colmugx/posoco-ext-webfetch", Some("webfetch")),
    // One logical `shell` capability, one package per platform: the host's
    // recipe builder picks by target, the roster names both.
    capability("bash", "colmugx/posoco-ext-bash", Some("shell")),
    capability("ps1", "colmugx/posoco-ext-ps1", Some("shell")),
    capability("skills", "colmugx/posoco-ext-skills", Some("skills")),
    capability(
      "askquestion",
      "colmugx/posoco-ext-askquestion",
      Some("askquestion"),
    ),
    capability("handoff", "colmugx/posoco-ext-handoff", Some("handoff")),
    capability("lazytools", "colmugx/posoco-ext-lazytools", Some("lazytools")),
  ]
}

///|
/// Capabilities one surface composes on top of the shared set, in roster
/// order. `None` entries in `recipe` are assembled by the host itself.
pub fn cetas_host_capabilities(host : String) -> Array[CetasCapability] {
  match host {
    "js" =>
      [
        capability("herdr", "posoco/ext-herdr", None),
        capability("mcp", "colmugx/posoco-ext-mcp", None),
        capability("plan", "colmugx/posoco-ext-plan", None),
        capability("pi_adaptor", "colmugx/posoco-ext-pi-adaptor", None),
        capability("stats", "colmugx/posoco-ext-stats", None),
        capability("statusbar", "colmugx/posoco-ext-statusbar", None),
        capability("subagent", "colmugx/posoco-ext-subagent", None),
        capability("kind", "colmugx/posoco-ext-kind", None),
        capability("subagent_kit", "colmugx/posoco-kit-subagent", None),
        capability("board", "colmugx/posoco-ext-board", None),
      ]
    "native" =>
      [
        capability("herdr", "posoco/ext-herdr", None),
        capability("mcp", "colmugx/posoco-ext-mcp", None),
        capability("plan", "colmugx/posoco-ext-plan", None),
        capability("stats", "colmugx/posoco-ext-stats", None),
        capability("statusbar", "colmugx/posoco-ext-statusbar", None),
        capability("subagent", "colmugx/posoco-ext-subagent", None),
        capability("kind", "colmugx/posoco-ext-kind", None),
        capability("subagent_kit", "colmugx/posoco-kit-subagent", None),
      ]
    "acp" =>
      [
        capability("ext_acp", "colmugx/posoco-ext-acp", None),
        capability("mcp", "colmugx/posoco-ext-mcp", None),
        capability("plan", "colmugx/posoco-ext-plan", None),
        capability("lody", "colmugx/posoco-kit-lody", None),
        capability("paseo", "colmugx/posoco-kit-paseo", None),
      ]
    "run" => [capability("herdr", "posoco/ext-herdr", None)]
    // The web host composes through the console core, so it inherits the
    // console-assembled rows. Presence stays off (the host does not set
    // `herdr_presence`) and the native-only delegation rows need the terminal
    // projection.
    "web" =>
      [
        capability("mcp", "colmugx/posoco-ext-mcp", None),
        capability("plan", "colmugx/posoco-ext-plan", None),
        capability("stats", "colmugx/posoco-ext-stats", None),
        capability("statusbar", "colmugx/posoco-ext-statusbar", None),
      ]
    _ => []
  }
}

///|
/// The full roster for one surface: shared capabilities first, then that
/// surface's own.
pub fn cetas_capabilities(host : String) -> Array[CetasCapability] {
  let entries = cetas_shared_capabilities()
  for extra in cetas_host_capabilities(host) {
    entries.push(extra)
  }
  entries
}

///|
/// Compiled-recipe keys for one surface, in product order and deduplicated —
/// this is exactly the array a host's `build_compiled_recipe_features` switch
/// iterates.
pub fn cetas_recipe_keys(host : String) -> Array[String] {
  let keys : Array[String] = []
  for entry in cetas_capabilities(host) {
    match entry.recipe {
      Some(key) => if !keys.contains(key) { keys.push(key) }
      None => ()
    }
  }
  keys
}

///|
/// Capability key to package for one surface. The map carries an entry for
/// every roster row, including the ones the host assembles itself: it is the
/// import list a reviewer checks a composition root against.
pub fn cetas_capability_packages(host : String) -> Map[String, String] {
  let packages : Map[String, String] = Map([])
  for entry in cetas_capabilities(host) {
    packages[entry.key] = entry.package_path
  }
  packages
}

///|
/// One capability's package on one surface, `None` when that surface does not
/// compose it.
pub fn cetas_capability_package(host : String, key : String) -> String? {
  for entry in cetas_capabilities(host) {
    if entry.key == key {
      return Some(entry.package_path)
    }
  }
  None
}

///|
test "roster: keys are unique per host and every host composes the shared set" {
  let shared = cetas_shared_capabilities()
  assert_true(shared.length() > 0)
  for host in cetas_roster_hosts() {
    let seen : Map[String, Unit] = Map([])
    for entry in cetas_capabilities(host) {
      assert_false(seen.contains(entry.key))
      seen[entry.key] = ()
      assert_true(entry.package_path.contains("/"))
    }
    let own = cetas_host_capabilities(host)
    for entry in shared {
      assert_true(cetas_capability_package(host, entry.key) is Some(_))
    }
    // A host entry may not shadow a shared one.
    for entry in own {
      assert_false(
        shared.any(fn(shared_entry) { shared_entry.key == entry.key }),
      )
    }
  }
}

///|
test "roster: recipe keys follow product order and dedupe the shell pair" {
  let keys = cetas_recipe_keys("native")
  assert_eq(keys[0], "forme")
  assert_eq(keys[4], "glob")
  assert_eq(keys[8], "shell")
  assert_eq(keys[keys.length() - 1], "lazytools")
  let shell_entries = cetas_capabilities("native").filter(fn(entry) {
    entry.recipe is Some("shell")
  })
  assert_eq(shell_entries.length(), 2)
}

///|
test "roster: only the js surface carries the js-only capabilities" {
  assert_true(cetas_capability_package("js", "pi_adaptor") is Some(_))
  assert_true(cetas_capability_package("native", "pi_adaptor") is None)
  assert_true(cetas_capability_package("native", "plan") is Some(_))
  assert_true(cetas_capability_package("native", "mcp") is Some(_))
  assert_true(cetas_capability_package("run", "stats") is None)
}
