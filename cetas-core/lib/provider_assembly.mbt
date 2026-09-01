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
  let deepseek = @deepseek.DeepSeekProvider(ctx~)
  let kimi = @kimi.KimiProvider(ctx~)
  let openai = @openai.OpenAIProvider()
  let opencode_zen = @opencode_zen.OpenCodeZenProvider(ctx~)
  let zai = @zai.ZaiProvider(ctx~)
  let zai_coding_plan = @zai_coding_plan.ZaiCodingPlanProvider(ctx~)
  let openrouter = @openrouter.OpenRouterProvider(ctx~)
  [
    deepseek as &@llm.ProviderFactory,
    kimi as &@llm.ProviderFactory,
    openai as &@llm.ProviderFactory,
    opencode_zen as &@llm.ProviderFactory,
    zai as &@llm.ProviderFactory,
    zai_coding_plan as &@llm.ProviderFactory,
    openrouter as &@llm.ProviderFactory,
  ]
}

///|
/// The set of provider ids claimed by statically-registered providers. Used to
/// decide which settings keys fall through to the openai-compatible adapter.
/// Returns a `Map[String, Unit]` used purely as a membership set. Includes the
/// OpenCode Zen gateway (`opencode`), so a `providers.opencode` settings entry
/// is claimed by the Zen factory rather than falling through.
pub fn static_provider_ids() -> Map[String, Unit] {
  let ctx = @devkit.ExtContext::default()
  let ids : Map[String, Unit] = Map::from_array([])
  for factory in provider_factories(ctx) {
    ids[factory.provider_id()] = ()
  }
  ids
}

///|
/// Construct one `OpenAICompatibleProvider` per settings key not already
/// claimed by a static provider. Returns owned instances so the caller can
/// borrow them as `&@llm.ProviderFactory` for the lifetime of composition.
pub fn compatible_provider_factories(
  settings : Map[String, Json],
  ctx : @devkit.ExtContext,
) -> Array[@openai_compatible.OpenAICompatibleProvider] {
  let claimed = static_provider_ids()
  let factories : Array[@openai_compatible.OpenAICompatibleProvider] = []
  for provider_id, _value in settings {
    // Belt-and-braces: composition has already failed fast on invalid ids
    // (validate_provider_settings); an unvalidated caller still cannot mint
    // a traversal id here.
    if !claimed.contains(provider_id) && valid_provider_id(provider_id) {
      factories.push(
        @openai_compatible.OpenAICompatibleProvider(provider_id, ctx~),
      )
    }
  }
  factories
}

///|
/// The complete, settings-aware factory list: static providers plus one
/// openai-compatible instance per custom settings id. Host composition
/// (catalog build, credential read, `/model`, `/login`) must use this list so
/// custom providers participate identically to static ones.
pub fn all_provider_factories(
  ctx : @devkit.ExtContext,
  settings : Map[String, Json],
) -> Array[&@llm.ProviderFactory] {
  let result : Array[&@llm.ProviderFactory] = []
  for factory in provider_factories(ctx) {
    result.push(factory)
  }
  for factory in compatible_provider_factories(settings, ctx) {
    result.push(factory as &@llm.ProviderFactory)
  }
  result
}

///|
/// Settings-aware `ApiKeyFactory` list: static api-key providers plus one
/// openai-compatible instance per custom settings id, so `/login <custom_id>
/// method:api_key` reaches the compatible provider.
pub fn all_api_key_factories(
  ctx : @devkit.ExtContext,
  settings : Map[String, Json],
) -> Array[&@llm.ApiKeyFactory] {
  let result : Array[&@llm.ApiKeyFactory] = []
  for factory in api_key_factories(ctx) {
    result.push(factory)
  }
  for factory in compatible_provider_factories(settings, ctx) {
    result.push(factory as &@llm.ApiKeyFactory)
  }
  result
}

///|
/// Registered `ApiKeyFactory` contributors. A provider that owns API-key
/// login advertises it here so capability discovery and `/login` reach the
/// same registered set.
pub fn api_key_factories(
  ctx : @devkit.ExtContext,
) -> Array[&@llm.ApiKeyFactory] {
  let deepseek = @deepseek.DeepSeekProvider(ctx~)
  let kimi = @kimi.KimiProvider(ctx~)
  let openai = @openai.OpenAIProvider()
  let opencode_zen = @opencode_zen.OpenCodeZenProvider(ctx~)
  let zai = @zai.ZaiProvider(ctx~)
  let zai_coding_plan = @zai_coding_plan.ZaiCodingPlanProvider(ctx~)
  let openrouter = @openrouter.OpenRouterApiKeyFactory()
  [
    deepseek as &@llm.ApiKeyFactory,
    kimi as &@llm.ApiKeyFactory,
    openai as &@llm.ApiKeyFactory,
    opencode_zen as &@llm.ApiKeyFactory,
    zai as &@llm.ApiKeyFactory,
    zai_coding_plan as &@llm.ApiKeyFactory,
    openrouter as &@llm.ApiKeyFactory,
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
  let kimi = @kimi.KimiProvider(ctx~, device_id~)
  let openai = @openai.OpenAIProvider()
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
  let deepseek = @deepseek.DeepSeekProvider(ctx~)
  let kimi = @kimi.KimiProvider(ctx~, device_id~)
  let openai = @openai.OpenAIProvider()
  let opencode_zen = @opencode_zen.OpenCodeZenProvider(ctx~)
  let zai = @zai.ZaiProvider(ctx~)
  let openrouter = @openrouter.OpenRouterProvider(ctx~)
  [
    deepseek as &@llm.RefreshableProviderFactory,
    kimi as &@llm.RefreshableProviderFactory,
    openai as &@llm.RefreshableProviderFactory,
    opencode_zen as &@llm.RefreshableProviderFactory,
    zai as &@llm.RefreshableProviderFactory,
    openrouter as &@llm.RefreshableProviderFactory,
  ]
}

///|
/// Provider ids are filesystem-safe by contract: nonempty, limited to
/// `[A-Za-z0-9_-]`. They become settings keys, credential filenames, and
/// login targets, so anything that could traverse a path (separators,
/// dots) is invalid at the boundary instead of being sanitized downstream.
pub fn valid_provider_id(id : String) -> Bool {
  if id.length() == 0 {
    return false
  }
  for i in 0..<id.length() {
    let c = id[i]
    let ok = (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '_' ||
      c == '-'
    if !ok {
      return false
    }
  }
  true
}

///|
/// Reject provider settings whose keys name no registered provider extension.
/// Composition stays fail-fast: an unknown provider id is a typed error rather
/// than a silent skip, so a typo in settings cannot produce a half-configured
/// agent. Keys must also be filesystem-safe provider ids (`valid_provider_id`)
/// — settings keys become credential filenames, so traversal shapes such as
/// `../evil` or `a/b` are rejected here, at the boundary.
pub fn validate_provider_settings(
  settings : Map[String, Json],
  factories : Array[&@llm.ProviderFactory],
) -> Unit raise @posoco.CompositionError {
  for provider_id, _value in settings {
    if !valid_provider_id(provider_id) {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas.providers",
        detail="settings provider id '" +
          provider_id +
          "' is not a valid provider id (allowed: letters, digits, '_', '-')",
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
      Json::String(value) if valid_provider_id(value) => value
      _ =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="cetas.providers",
          detail="model refresh provider ids must be non-empty strings of letters, digits, '_', '-'",
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
