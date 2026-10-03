///|
/// Providers that can become runnable from an API-key credential alone. These
/// are intentionally stricter than the runtime's full provider registry:
/// DeepSeek and OpenRouter need non-secret model settings before their static
/// build can yield a slot, so they are configured after ignition.
priv struct BootstrapProvider {
  id : String
  label : String
  factory : &@llm.ProviderFactory
  api_key : &@llm.ApiKeyFactory
}

///|
fn bootstrap_providers() -> Array[BootstrapProvider] {
  let ctx = @devkit.ExtContext::default()
  let openai = @openai.OpenAIProvider()
  let kimi = @kimi.KimiProvider(ctx~)
  let opencode = @opencode_zen.OpenCodeZenProvider(ctx~)
  let zai = @zai.ZaiProvider(ctx~)
  let zai_plan = @zai_coding_plan.ZaiCodingPlanProvider(ctx~)
  [
    {
      id: "openai",
      label: "OpenAI API",
      factory: openai as &@llm.ProviderFactory,
      api_key: openai as &@llm.ApiKeyFactory,
    },
    {
      id: "kimi",
      label: "Kimi / Moonshot API",
      factory: kimi as &@llm.ProviderFactory,
      api_key: kimi as &@llm.ApiKeyFactory,
    },
    {
      id: "opencode",
      label: "OpenCode Zen",
      factory: opencode as &@llm.ProviderFactory,
      api_key: opencode as &@llm.ApiKeyFactory,
    },
    {
      id: "zai",
      label: "Z.ai / BigModel",
      factory: zai as &@llm.ProviderFactory,
      api_key: zai as &@llm.ApiKeyFactory,
    },
    {
      id: "zai-coding-plan",
      label: "Z.ai Coding Plan",
      factory: zai_plan as &@llm.ProviderFactory,
      api_key: zai_plan as &@llm.ApiKeyFactory,
    },
  ]
}

///|
async fn select_bootstrap_provider(
  providers : Array[BootstrapProvider],
  requested : String,
  prompt : &@oauth.AuthPromptInteraction,
) -> BootstrapProvider raise @oauth.OAuthError {
  let id = if requested != "" {
    requested
  } else {
    prompt.prompt(
      @oauth.AuthPromptRequest::Select(
        message="Select a provider to bootstrap Cetas for Memoh",
        options=providers.map(fn(provider) {
          @oauth.AuthPromptOption::AuthPromptOption(
            id=provider.id,
            label=provider.label,
          )
        }),
      ),
    )
  }
  for provider in providers {
    if provider.id == id {
      return provider
    }
  }
  raise @oauth.OAuthError::ParseError(
    "unsupported bootstrap provider: " +
    id +
    " (choose openai, kimi, opencode, zai, or zai-coding-plan)",
  )
}

///|
async fn setup_with_prompt(
  home : String,
  requested : String,
  prompt : &@oauth.AuthPromptInteraction,
) -> String {
  let fs_impl = @workspace.NativeWorkspaceFs()
  let fs : &@workspace.WorkspaceFs = fs_impl
  let settings = load_provider_settings(fs, home)
  let selected = select_bootstrap_provider(
    bootstrap_providers(),
    requested,
    prompt,
  )
  let api_key = selected.api_key.login(prompt)
  let credential = @oauth.ProviderCredential::ApiKey(api_key)
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=settings.get(selected.id),
    provider_credential=Some(credential),
  )
  let catalog = match selected.factory.build(source) {
    @llm.ProviderBuildResult::Ready(value) => value
    @llm.ProviderBuildResult::Unconfigured =>
      fail(
        "provider accepted the credential but still needs non-secret settings; " +
        "bootstrap refused to persist a non-runnable configuration",
      )
  }
  let slots = catalog.slots()
  if slots.is_empty() {
    fail("provider produced an empty model catalog; credential was not saved")
  }
  let store = @credentials.FileProviderCredentialStore(
    fs,
    credentials_path(home),
  )
  store.write(selected.id, credential)
  // Exercise the normal production assembly after persistence. A successful
  // setup means the next plain cetas-memoh process can cross the same gate.
  let platform = build_provider_platform(fs, home)
  if platform.catalogs.is_empty() {
    fail(
      "credential was saved but the production provider platform stayed empty",
    )
  }
  "configured " +
  selected.id +
  " (" +
  slots.length().to_string() +
  " model slot" +
  (if slots.length() == 1 { "" } else { "s" }) +
  ")"
}

///|
/// Trusted first-run ignition. Secret input is read from the controlling TTY,
/// never ACP stdin or argv.
pub async fn run_setup(home~ : String, provider? : String = "") -> String {
  with_setup_prompt(async fn(prompt) {
    setup_with_prompt(home, provider, prompt)
  })
}
