///|
/// Resident prompt hints for the deferred tool owners this composition hides.
///
/// A deferred owner loses its schemas from every model request, so the only
/// thing left in the resident prompt is a one-line hint per owner. Spelled once
/// here instead of per host: the owner ids are composition facts (manifest
/// ids), not host facts.

///|
pub fn deferred_tool_hints() -> Map[String, String] {
  Map::from_array([
    ("posoco_ext_webfetch", "fetch one URL as readable markdown"),
    ("posoco_ext_nowledge_mem", "cross-session memory search and save"),
    ("posoco_ext_obsidian", "search, read, and edit the Obsidian vault"),
    ("posoco_ext_mcp", "tools published by the configured MCP servers"),
  ])
}
