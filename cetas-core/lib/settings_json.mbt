///|
/// Parse user settings, accepting a single leading UTF-8 byte-order mark.
/// Schema validation remains the responsibility of each settings consumer.
///
/// ```mbt check
/// test {
///   json_inspect(
///     @lib.parse_settings_json("\uFEFF{}", manifest_id="cetas.settings"),
///     content={},
///   )
/// }
/// ```
pub fn parse_settings_json(
  text : String,
  manifest_id~ : String,
) -> Json raise @posoco.CompositionError {
  let source = text.strip_prefix("\uFEFF").unwrap_or(text[:])
  @json.parse(source) catch {
    error =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id~,
        detail=".cetas/settings.json is not valid JSON: " + error.to_string(),
      )
  }
}
