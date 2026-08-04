///|
/// provider_assembly.mbt — Provider factory wiring shared by every cetas host.
///
/// Cetas owns only generic sources (settings JSON, credential files) and the
/// registration of public provider-extension seams. Provider extensions receive
/// an opaque `ProviderConfigSource` and own defaults, endpoint/path handling,
/// protocol, model capabilities, and OAuth credential rebuilding. There is
/// deliberately no provider-id switch or legacy environment fallback here.
///
/// This module is target-agnostic: it depends only on the public provider
/// extension traits and pure MoonBit. Host-specific persistence (device-id
/// minting, atomic file writes) is injected by the caller; `device_id` arrives
/// as a plain parameter so this module never performs IO.

///|
/// Registered `ProviderFactory` contributors for the current cetas build.
///
/// The factory list is the single source of truth for which providers a host
/// can compose; setup discovery, `/model`, `/login`, and catalog refresh all
/// reuse it so they cannot diverge.
pub fn provider_factories(
  ctx : @devkit.ExtContext,
) -> Array[&@llm.ProviderFactory] {
  let deepseek = @deepseek.DeepSeekProvider::new(ctx~)
  let kimi = @kimi.KimiProvider::new(ctx~)
  let openai = @openai.OpenAIProvider::new()
  [
    deepseek as &@llm.ProviderFactory,
    kimi as &@llm.ProviderFactory,
    openai as &@llm.ProviderFactory,
  ]
}

///|
/// Registered `ApiKeyFactory` contributors. A provider that owns API-key
/// login advertises it here so capability discovery and `/login` reach the
/// same registered set.
pub fn api_key_factories(
  ctx : @devkit.ExtContext,
) -> Array[&@llm.ApiKeyFactory] {
  let deepseek = @deepseek.DeepSeekProvider::new(ctx~)
  let kimi = @kimi.KimiProvider::new(ctx~)
  let openai = @openai.OpenAIProvider::new()
  [
    deepseek as &@llm.ApiKeyFactory,
    kimi as &@llm.ApiKeyFactory,
    openai as &@llm.ApiKeyFactory,
  ]
}

///|
/// Registered `OAuthFactory` contributors. `device_id` is resolved by the host
/// (it requires host-specific persistent storage) and passed in; an empty
/// value is used for capability enumeration paths that never issue an OAuth
/// request.
pub fn oauth_factories(
  ctx : @devkit.ExtContext,
  device_id? : String = "",
) -> Array[&@llm.OAuthFactory] {
  let kimi = @kimi.KimiProvider::new(ctx~, device_id~)
  let openai = @openai.OpenAIProvider::new()
  [kimi as &@llm.OAuthFactory, openai as &@llm.OAuthFactory]
}

///|
/// Optional live model-discovery seams. Providers that do not implement this
/// contract still participate through their pure static `build` snapshot;
/// Cetas never invents an endpoint or a fallback request for them. As with
/// `oauth_factories`, `device_id` is supplied by the host.
pub fn refreshable_factories(
  ctx : @devkit.ExtContext,
  device_id? : String = "",
) -> Array[&@llm.RefreshableProviderFactory] {
  let deepseek = @deepseek.DeepSeekProvider::new(ctx~)
  let kimi = @kimi.KimiProvider::new(ctx~, device_id~)
  let openai = @openai.OpenAIProvider::new()
  [
    deepseek as &@llm.RefreshableProviderFactory,
    kimi as &@llm.RefreshableProviderFactory,
    openai as &@llm.RefreshableProviderFactory,
  ]
}

///|
/// Reject provider settings whose keys name no registered provider extension.
/// Composition stays fail-fast: an unknown provider id is a typed error rather
/// than a silent skip, so a typo in settings cannot produce a half-configured
/// agent.
pub fn validate_provider_settings(
  settings : Map[String, Json],
  factories : Array[&@llm.ProviderFactory],
) -> Unit raise @posoco.CompositionError {
  for provider_id, _value in settings {
    let mut known = false
    for factory in factories {
      if factory.provider_id() == provider_id {
        known = true
      }
    }
    if !known {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas.providers",
        detail="no registered provider extension for settings.providers." +
          provider_id,
      )
    }
  }
}

///|
/// Parse the provider-neutral refresh selector supplied by a host. An empty
/// string means all registered providers; otherwise it must be a JSON array of
/// provider ids. Provider ids are validated against the same factory registry
/// used for composition, keeping endpoint/model interpretation out of Cetas.
pub fn parse_refresh_provider_ids(
  raw : String,
) -> Array[String]? raise @posoco.CompositionError {
  if raw.length() == 0 {
    return None
  }
  let json = @json.parse(raw) catch {
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas.providers",
        detail="model refresh provider selector is not valid JSON",
      )
  }
  let values = match json {
    Json::Array(values) => values
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas.providers",
        detail="model refresh provider selector must be an array",
      )
  }
  let factories = provider_factories(@devkit.ExtContext::default())
  let ids : Array[String] = []
  for value in values {
    let provider_id = match value {
      Json::String(value) if value.length() > 0 => value
      _ =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="cetas.providers",
          detail="model refresh provider ids must be non-empty strings",
        )
    }
    let mut known = false
    for factory in factories {
      if factory.provider_id() == provider_id {
        known = true
      }
    }
    if !known {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas.providers",
        detail="no registered provider extension for model refresh: " +
          provider_id,
      )
    }
    if !ids.contains(provider_id) {
      ids.push(provider_id)
    }
  }
  Some(ids)
}
