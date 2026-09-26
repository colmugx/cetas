///|
/// Product-local provider composition. This file deliberately does not import
/// cetas-core: cetas-memoh owns its provider registry and durable layout.

pub(all) struct ProviderIssue {
  provider_id : String
  detail : String
}

///|
pub(all) struct ProviderPlatform {
  catalogs : Array[@llm.ProviderModelCatalog]
  credential_store : @credentials.FileProviderCredentialStore
  issues : Array[ProviderIssue]
}

///|
fn valid_provider_id(id : String) -> Bool {
  if id.is_empty() {
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
fn static_provider_factories(
  ctx : @devkit.ExtContext,
) -> Array[&@llm.ProviderFactory] {
  let deepseek = @deepseek.DeepSeekProvider(ctx~)
  let kimi = @kimi.KimiProvider(ctx~)
  let openai = @openai.OpenAIProvider()
  let opencode = @opencode_zen.OpenCodeZenProvider(ctx~)
  let openrouter = @openrouter.OpenRouterProvider(ctx~)
  let zai = @zai.ZaiProvider(ctx~)
  let zai_coding_plan = @zai_coding_plan.ZaiCodingPlanProvider(ctx~)
  [
    deepseek as &@llm.ProviderFactory,
    kimi as &@llm.ProviderFactory,
    openai as &@llm.ProviderFactory,
    opencode as &@llm.ProviderFactory,
    openrouter as &@llm.ProviderFactory,
    zai as &@llm.ProviderFactory,
    zai_coding_plan as &@llm.ProviderFactory,
  ]
}

///|
fn provider_factories(
  ctx : @devkit.ExtContext,
  settings : Map[String, Json],
) -> Array[&@llm.ProviderFactory] {
  let result : Array[&@llm.ProviderFactory] = []
  let claimed : Map[String, Unit] = Map::from_array([])
  for factory in static_provider_factories(ctx) {
    claimed[factory.provider_id()] = ()
    result.push(factory)
  }
  for provider_id, _ in settings {
    if !valid_provider_id(provider_id) {
      continue
    }
    if !claimed.contains(provider_id) {
      let compatible = @openai_compatible.OpenAICompatibleProvider(
        provider_id,
        ctx~,
      )
      result.push(compatible as &@llm.ProviderFactory)
    }
  }
  result
}

///|
/// providers.json is a direct object keyed by provider id. Provider-specific
/// values are opaque to this host and are interpreted only by their extension.
pub async fn load_provider_settings(
  fs : &@workspace.WorkspaceFs,
  home : String,
) -> Map[String, Json] raise @posoco.CompositionError {
  match @workspace.read_file_result(fs, providers_path(home)) {
    Missing => Map::from_array([])
    Failed(message) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas-memoh.providers",
        detail="providers.json read failed: " + message,
      )
    Content(text) => {
      let parsed = @json.parse(text) catch {
        _ =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="cetas-memoh.providers",
            detail="providers.json is not valid JSON",
          )
      }
      match parsed {
        Json::Object(settings) => {
          for provider_id, _ in settings {
            if !valid_provider_id(provider_id) {
              raise @posoco.CompositionError::ManifestSchemaError(
                manifest_id="cetas-memoh.providers",
                detail="invalid provider id '" + provider_id + "'",
              )
            }
          }
          settings
        }
        _ =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="cetas-memoh.providers",
            detail="providers.json must be an object keyed by provider id",
          )
      }
    }
  }
}

///|
pub async fn build_provider_platform(
  fs : &@workspace.WorkspaceFs,
  home : String,
) -> ProviderPlatform raise @posoco.CompositionError {
  let settings = load_provider_settings(fs, home)
  let ctx = @devkit.ExtContext::default()
  let factories = provider_factories(ctx, settings)
  let store = @credentials.FileProviderCredentialStore(
    fs,
    credentials_path(home),
  )
  let catalogs : Array[@llm.ProviderModelCatalog] = []
  let issues : Array[ProviderIssue] = []

  for factory in factories {
    let provider_id = factory.provider_id()
    let credential_result : Result[@oauth.ProviderCredential?, Error] = try {
      Ok(store.read(provider_id))
    } catch {
      error => Err(error)
    }
    let credential = match credential_result {
      Ok(value) => value
      Err(error) => {
        issues.push({ provider_id, detail: error.to_string(), })
        continue
      }
    }
    let provider_settings = settings.get(provider_id)
    let source = @llm.ProviderConfigSource::ProviderConfigSource(
      settings=provider_settings,
      provider_credential=credential,
      credential_store=Some(store),
    )
    let built : Result[@llm.ProviderBuildResult, Error] = try {
      Ok(factory.build(source))
    } catch {
      error => Err(error)
    }
    match built {
      Ok(@llm.ProviderBuildResult::Ready(catalog)) => catalogs.push(catalog)
      Ok(@llm.ProviderBuildResult::Unconfigured) => ()
      Err(error) =>
        issues.push({ provider_id, detail: error.to_string(), })
    }
  }

  if catalogs.is_empty() {
    raise @posoco.CompositionError::EmptyPort(
      "cetas-memoh.providers: no configured model provider; configure " +
      providers_path(home) +
      " and provider credentials under " +
      credentials_path(home),
    )
  }
  { catalogs, credential_store: store, issues, }
}
