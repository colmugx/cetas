///|
/// One login-capable provider. Capabilities are supplied by each product's
/// registered Provider factories, not inferred from provider names.
pub(all) struct LoginCandidate {
  id : String
  methods : Array[String]
}

///|
/// A successful authentication. The caller owns storage and post-login policy.
pub(all) struct AuthenticatedLogin {
  provider : String
  auth_method : String
  credential : @oauth.ProviderCredential
}

///|
/// Merge advertised API-key and OAuth providers without duplicating choices.
pub fn login_candidates(
  api_key : Array[String],
  oauth : Array[String],
) -> Array[LoginCandidate] {
  let result : Array[LoginCandidate] = []
  for id in api_key {
    if result.any(fn(value) { value.id == id }) {
      continue
    }
    result.push({ id, methods: ["api_key"], })
  }
  for id in oauth {
    let mut found = false
    for entry in result {
      if entry.id == id {
        if !entry.methods.contains("oauth") {
          entry.methods.push("oauth")
        }
        found = true
        break
      }
    }
    if !found {
      result.push({ id, methods: ["oauth"], })
    }
  }
  result
}

///|
/// Explicit cancellation gate before every credential-affecting step.
pub fn require_login_active(
  interaction : &@oauth.AuthInteraction,
) -> Unit raise @posoco.CommandError {
  if interaction.is_cancelled() {
    raise @posoco.CommandError::ExecutionFailed("Login cancelled")
  }
}

///|
/// Select a provider or method. Invalid input is not echoed: it might be a
/// pasted secret. Cancellation is checked on both sides of an async prompt.
pub async fn choose_login_option(
  interaction : &@oauth.AuthInteraction,
  prompt : &@oauth.AuthPromptInteraction,
  message : String,
  options : Array[@oauth.AuthPromptOption],
) -> String raise @posoco.CommandError {
  require_login_active(interaction)
  let selected = prompt.prompt(
    @oauth.AuthPromptRequest::Select(message~, options~),
  ) catch {
    @oauth.OAuthError::Cancelled =>
      raise @posoco.CommandError::ExecutionFailed("Login cancelled")
    _ => raise @posoco.CommandError::ExecutionFailed("Login selection failed")
  }
  require_login_active(interaction)
  if options.any(fn(item) { item.id == selected }) {
    selected
  } else {
    raise @posoco.CommandError::InvalidArgs(reason="Invalid login selection")
  }
}

///|
/// Reusable, testable authentication mechanism. Run and Memoh inject their
/// own ProviderFactory execution, credential storage and readiness policy.
pub async fn authenticate_login(
  candidates : Array[LoginCandidate],
  requested~ : String = "",
  interaction : &@oauth.AuthInteraction,
  prompt : &@oauth.AuthPromptInteraction,
  authenticate : async (
    String,
    String,
    &@oauth.AuthInteraction,
    &@oauth.AuthPromptInteraction,
  ) -> @oauth.ProviderCredential,
) -> AuthenticatedLogin raise @posoco.CommandError {
  let provider = if requested.is_empty() {
    choose_login_option(
      interaction,
      prompt,
      "Select login provider",
      candidates.map(fn(value) {
        @oauth.AuthPromptOption::AuthPromptOption(
          id=value.id,
          label=value.id,
        )
      }),
    )
  } else {
    requested
  }
  let mut methods : Array[String] = []
  for candidate in candidates {
    if candidate.id == provider {
      methods = candidate.methods
      break
    }
  }
  if methods.is_empty() {
    raise @posoco.CommandError::InvalidArgs(
      reason="Unknown login provider; select a registered authentication provider",
    )
  }
  let auth_method = if methods.length() == 1 {
    methods[0]
  } else {
    choose_login_option(
      interaction,
      prompt,
      "Select authentication method",
      methods.map(fn(id) {
        @oauth.AuthPromptOption::AuthPromptOption(
          id~,
          label=if id == "oauth" { "OAuth / browser login" } else { "API key" },
        )
      }),
    )
  }
  require_login_active(interaction)
  let credential = authenticate(provider, auth_method, interaction, prompt) catch {
    _ => {
      require_login_active(interaction)
      raise @posoco.CommandError::ExecutionFailed(
        "Authentication failed or was cancelled; credentials were not saved",
      )
    }
  }
  require_login_active(interaction)
  { provider, auth_method, credential, }
}
