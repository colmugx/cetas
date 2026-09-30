///|
#cfg(target="native")
fn mint_login_device_id() -> String raise @posoco.CommandError {
  // UUID v4 shape, shared with cetas-js's crypto.randomUUID device file.
  let bytes = match @env.rand(16) {
    Some(bytes) if bytes.length() == 16 => bytes
    _ =>
      raise @posoco.CommandError::ExecutionFailed(
        "Cannot mint persistent login device id",
      )
  }
  let hex = "0123456789abcdef"
  let out = StringBuilder()
  for i in 0..<16 {
    if i == 4 || i == 6 || i == 8 || i == 10 {
      out.write_string("-")
    }
    let byte = if i == 6 {
      (bytes[i].to_int() & 15) | 64
    } else if i == 8 {
      (bytes[i].to_int() & 63) | 128
    } else {
      bytes[i].to_int()
    }
    out.write_string(hex[byte >> 4:(byte >> 4) + 1].to_owned())
    out.write_string(hex[byte & 15:(byte & 15) + 1].to_owned())
  }
  out.to_string()
}

///|
/// Authenticate without constructing an Agent or generating a model turn.
#cfg(target="native")
pub async fn run_login(
  home~ : String,
  provider~ : String,
  note~ : async (String) -> Unit noraise,
) -> Unit {
  with_terminal_auth(note~, body=async fn(interaction, prompt) {
    run_login_with_interactions(
      home~,
      provider~,
      note~,
      fs=@workspace.NativeWorkspaceFs(),
      interaction~,
      prompt~,
      mint_device_id=mint_login_device_id,
    )
  })
}

///|
/// Login uses core's authentication capabilities, not its ready model slots.
priv struct LoginProvider {
  id : String
  auth_methods : Array[String]
}

///|
fn login_providers(settings : Map[String, Json]) -> Array[LoginProvider] {
  let ctx = @devkit.ExtContext::default()
  let providers : Array[LoginProvider] = []
  let add = fn(id : String, auth_method : String) {
    for provider in providers {
      if provider.id == id {
        if !provider.auth_methods.contains(auth_method) {
          provider.auth_methods.push(auth_method)
        }
        return
      }
    }
    providers.push({ id, auth_methods: [auth_method], })
  }
  for factory in @cetas_core.all_api_key_factories(ctx, settings) {
    add(factory.provider_id(), "api_key")
  }
  for factory in @cetas_core.oauth_factories(ctx) {
    add(factory.provider_id(), "oauth")
  }
  providers
}

///|
/// Only authentication and live discovery are replaceable in tests. Storage,
/// snapshots, capability selection, cache, and settings always use real seams.
priv struct LoginDriver {
  login : async (
    String,
    String,
    Map[String, Json],
    String,
    &@oauth.AuthInteraction,
    &@oauth.AuthPromptInteraction,
  ) -> @cetas_core.LoginOutcome
  refresh : async (String, String, @cetas_core.ProviderCredentialSnapshot) -> @llm.ProviderModelCatalog?
}

///|
fn core_login_driver() -> LoginDriver {
  {
    login: async fn(
      provider,
      auth_method,
      settings,
      device_id,
      interaction,
      prompt,
    ) {
      @cetas_core.login_provider(
        provider,
        auth_method,
        settings~,
        device_id~,
        interaction,
        prompt,
      )
    },
    refresh: async fn(provider, device_id, snapshot) {
      let ctx = @devkit.ExtContext::default()
      for factory in @cetas_core.refreshable_factories(ctx, device_id~) {
        if factory.provider_id() == provider {
          return @cetas_core.refresh_provider_catalog(factory, snapshot)
        }
      }
      // A static-only provider has no live discovery capability. Never fall
      // back here after a failed refresh of a refreshable provider.
      for factory in @cetas_core.all_provider_factories(ctx, snapshot.settings) {
        if factory.provider_id() == provider {
          return @cetas_core.build_provider_catalog(factory, snapshot)
        }
      }
      None
    },
  }
}

///|
fn check_login_cancelled(
  interaction : &@oauth.AuthInteraction,
) -> Unit raise @posoco.CommandError {
  if interaction.is_cancelled() {
    raise @posoco.CommandError::ExecutionFailed("Login cancelled")
  }
}

///|
async fn login_select(
  interaction : &@oauth.AuthInteraction,
  prompt : &@oauth.AuthPromptInteraction,
  message : String,
  options : Array[@oauth.AuthPromptOption],
) -> String raise @posoco.CommandError {
  check_login_cancelled(interaction)
  let selected = prompt.prompt(
    @oauth.AuthPromptRequest::Select(message~, options~),
  ) catch {
    @oauth.OAuthError::Cancelled =>
      raise @posoco.CommandError::ExecutionFailed("Login cancelled")
    _ => raise @posoco.CommandError::ExecutionFailed("Login selection failed")
  }
  check_login_cancelled(interaction)
  for option in options {
    if option.id == selected {
      return selected
    }
  }
  // Do not echo invalid input: a mistaken paste may contain a secret.
  raise @posoco.CommandError::InvalidArgs(reason="Invalid login selection")
}

///|
async fn login_device_id(
  fs : &@workspace.WorkspaceFs,
  home : String,
  mint : () -> String raise @posoco.CommandError,
) -> String raise @posoco.CommandError {
  let path = @cetas_core.cetas_dir(home) + "/kimi_device_id"
  match @workspace.read_file_result(fs, path) {
    Content(text) if text.trim().length() > 0 => text.trim().to_owned()
    Failed(_) =>
      raise @posoco.CommandError::ExecutionFailed(
        "Cannot read persistent login device id",
      )
    _ => {
      let id = mint()
      fs.mkdir(@cetas_core.cetas_dir(home), recursive=true) catch {
        _ =>
          raise @posoco.CommandError::ExecutionFailed(
            "Cannot save persistent login device id",
          )
      }
      fs.write_file_atomic(path, id) catch {
        _ =>
          raise @posoco.CommandError::ExecutionFailed(
            "Cannot save persistent login device id",
          )
      }
      id
    }
  }
}

///|
async fn run_login_with_interactions(
  home~ : String,
  provider~ : String,
  note~ : async (String) -> Unit noraise,
  fs~ : &@workspace.WorkspaceFs,
  interaction~ : &@oauth.AuthInteraction,
  prompt~ : &@oauth.AuthPromptInteraction,
  mint_device_id~ : () -> String raise @posoco.CommandError,
  driver? : LoginDriver = core_login_driver(),
) -> Unit {
  let settings = @cetas_core.load_provider_settings(
    fs,
    home~,
    label="cetas-run.login",
  ) catch {
    _ =>
      raise @posoco.CommandError::ExecutionFailed(
        "Cannot read login provider settings",
      )
  }
  let factories = @cetas_core.all_provider_factories(
    @devkit.ExtContext::default(),
    settings,
  )
  @cetas_core.validate_provider_settings(settings, factories) catch {
    _ =>
      raise @posoco.CommandError::ExecutionFailed(
        "Invalid login provider settings",
      )
  }
  let active = @cetas_core.read_active_model_selection(fs, home~) catch {
    _ =>
      raise @posoco.CommandError::ExecutionFailed(
        "Cannot read persisted model selection",
      )
  }
  let providers = login_providers(settings)
  let selected_provider = if provider.is_empty() {
    let options = providers.map(fn(p) {
      @oauth.AuthPromptOption::AuthPromptOption(id=p.id, label=p.id)
    })
    login_select(interaction, prompt, "Select login provider", options)
  } else {
    provider
  }
  let auth_methods : Array[String] = []
  for p in providers {
    if p.id == selected_provider {
      auth_methods.append(p.auth_methods)
    }
  }
  if auth_methods.is_empty() {
    raise @posoco.CommandError::InvalidArgs(
      reason="Unknown login provider; select a registered authentication provider",
    )
  }
  let auth_method = if auth_methods.length() == 1 {
    auth_methods[0]
  } else {
    login_select(
      interaction,
      prompt,
      "Select authentication method",
      auth_methods.map(fn(id) {
        @oauth.AuthPromptOption::AuthPromptOption(
          id~,
          label=if id == "oauth" { "OAuth / browser login" } else { "API key" },
        )
      }),
    )
  }
  check_login_cancelled(interaction)
  let device_id = if selected_provider == "kimi" && auth_method == "oauth" {
    login_device_id(fs, home, mint_device_id)
  } else {
    ""
  }
  let outcome = (driver.login)(
    selected_provider, auth_method, settings, device_id, interaction, prompt,
  ) catch {
    _ => {
      check_login_cancelled(interaction)
      raise @posoco.CommandError::ExecutionFailed(
        "Authentication failed or was cancelled; credentials were not saved",
      )
    }
  }
  check_login_cancelled(interaction)
  if outcome.provider_id != selected_provider ||
    outcome.login_method != auth_method {
    raise @posoco.CommandError::ExecutionFailed(
      "Authentication returned an inconsistent provider or method",
    )
  }
  let store = @credentials.FileProviderCredentialStore(
    fs,
    @cetas_core.credentials_path(home),
  )
  store.write(selected_provider, outcome.credential) catch {
    _ =>
      raise @posoco.CommandError::ExecutionFailed(
        "Authentication completed, but credentials could not be saved; catalog was not refreshed",
      )
  }
  note("Authentication saved for " + selected_provider + "\n")
  let catalog = try {
    let snapshot = @cetas_core.read_credential_snapshot(
      store,
      factories,
      settings~,
      label="cetas-run.login",
    )
    (driver.refresh)(selected_provider, device_id, snapshot)
  } catch {
    _ =>
      raise @posoco.CommandError::ExecutionFailed(
        "Authentication saved for " +
        selected_provider +
        ", but catalog refresh failed; saved credentials were retained. Retry catalog refresh in Cetas with the same home",
      )
  }
  match catalog {
    None =>
      note(
        "Authentication saved, but no model catalog is available; use Cetas /model after configuring this provider\n",
      )
    Some(catalog) => {
      @cetas_core.write_model_list_cache(
        fs,
        home~,
        selected_provider,
        @cetas_core.catalog_model_records(catalog),
      ) catch {
        _ =>
          raise @posoco.CommandError::ExecutionFailed(
            "Authentication saved, but refreshed model catalog could not be cached; saved credentials were retained",
          )
      }
      // Preserve even a pending selection belonging to another provider.
      if active is Some(_) {
        return
      }
      let slots = catalog.slots()
      if slots.is_empty() {
        note("No models were discovered; use Cetas /model with the same home\n")
        return
      }
      let selected = if slots.length() == 1 {
        check_login_cancelled(interaction)
        slots[0].id
      } else {
        login_select(
          interaction,
          prompt,
          "Select initial model (authentication is already saved)",
          slots.map(fn(slot) {
            @oauth.AuthPromptOption::AuthPromptOption(
              id=slot.id,
              label=slot.label,
            )
          }),
        )
      }
      // Re-read before writing so a selection made during authentication wins.
      let current = @cetas_core.read_active_model_selection(fs, home~) catch {
        _ =>
          raise @posoco.CommandError::ExecutionFailed(
            "Authentication saved, but persisted model selection could not be read",
          )
      }
      if current is None {
        @cetas_core.write_active_model_selection(
          fs,
          home~,
          @cetas_core.ActiveModelSelection::ActiveModelSelection(selected),
        ) catch {
          _ =>
            raise @posoco.CommandError::ExecutionFailed(
              "Authentication saved, but initial model selection could not be saved",
            )
        }
        note("Initial model saved: " + selected + "\n")
      }
    }
  }
}
