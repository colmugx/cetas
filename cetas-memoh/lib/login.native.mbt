///|
/// Memoh owns its Provider Registry, home, credentials and startup readiness.
/// Only the authentication mechanism and controlling-terminal prompts come
/// from cetas-bootstrap. No cetas-core state is imported.
fn memoh_login_candidates(
  settings : Map[String, Json],
) -> Array[@bootstrap.LoginCandidate] {
  let ctx = @devkit.ExtContext::default()
  let api : Array[String] = []
  for factory in memoh_api_key_factories(settings, ctx) {
    api.push(factory.provider_id())
  }
  let oauth : Array[String] = []
  for factory in memoh_oauth_factories(ctx) {
    oauth.push(factory.provider_id())
  }
  @bootstrap.login_candidates(api, oauth)
}

///|
fn memoh_api_key_factories(
  settings : Map[String, Json],
  ctx : @devkit.ExtContext,
) -> Array[&@llm.ApiKeyFactory] {
  let keys : Array[&@llm.ApiKeyFactory] = [
    @deepseek.DeepSeekProvider(ctx~),
    @kimi.KimiProvider(ctx~),
    @openai.OpenAIProvider(),
    @opencode_zen.OpenCodeZenProvider(ctx~),
    @openrouter.OpenRouterApiKeyFactory(),
    @zai.ZaiProvider(ctx~),
    @zai_coding_plan.ZaiCodingPlanProvider(ctx~),
  ]
  for id, _ in settings {
    if !static_provider_factories(ctx).any(fn(factory) {
        factory.provider_id() == id
      }) {
      keys.push(@custom.CustomProvider(id, ctx~))
    }
  }
  keys
}

///|
fn memoh_oauth_factories(
  ctx : @devkit.ExtContext,
  device_id~ : String = "",
) -> Array[&@llm.OAuthFactory] {
  [@kimi.KimiProvider(ctx~, device_id~), @openai.OpenAIProvider()]
}

///|
/// Keep device identity inside Memoh's own durable home; it must not leak
/// into generic Cetas or change when an ACP session is replaced.
fn memoh_mint_device_id() -> String raise @posoco.CommandError {
  let bytes = match @env.rand(16) {
    Some(data) if data.length() == 16 => data
    _ =>
      raise @posoco.CommandError::ExecutionFailed(
        "Cannot mint persistent login device id",
      )
  }
  let hex = "0123456789abcdef"
  let result = StringBuilder()
  for i in 0..<16 {
    if i == 4 || i == 6 || i == 8 || i == 10 {
      result.write_string("-")
    }
    let byte = if i == 6 {
      (bytes[i].to_int() & 15) | 64
    } else if i == 8 {
      (bytes[i].to_int() & 63) | 128
    } else {
      bytes[i].to_int()
    }
    result.write_string(hex[byte >> 4:(byte >> 4) + 1].to_owned())
    result.write_string(hex[byte & 15:(byte & 15) + 1].to_owned())
  }
  result.to_string()
}

///|
async fn memoh_device_id(
  fs : &@workspace.WorkspaceFs,
  home : String,
) -> String raise @posoco.CommandError {
  let path = home + "/kimi_device_id"
  match @workspace.read_file_result(fs, path) {
    Content(value) if !value.trim().is_empty() => value.trim().to_owned()
    Failed(_) =>
      raise @posoco.CommandError::ExecutionFailed(
        "Cannot read persistent login device id",
      )
    _ => {
      let id = memoh_mint_device_id()
      fs.mkdir(home, recursive=true) catch {
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
/// Credential commit is the only durable mutation during login. A provider
/// can authenticate successfully yet still need non-secret model settings;
/// unlike setup, login does not require a runnable model to save auth.
pub async fn run_memoh_login(home~ : String, provider~ : String = "") -> Unit {
  let fs = @workspace.NativeWorkspaceFs()
  let settings = load_provider_settings(fs, home)
  let ctx = @devkit.ExtContext::default()
  let candidates = memoh_login_candidates(settings)
  @bootstrap.with_terminal_auth(
    note=async fn(message) noraise {
      @stdio.stderr.write(@utf8.encode(message)[:]) catch {
        _ => ()
      }
    },
    body=async fn(interaction, prompt) {
      let login = @bootstrap.authenticate_login(
        candidates,
        interaction,
        prompt,
        async fn(id, auth_method, auth_interaction, auth_prompt) {
          if auth_method == "api_key" {
            for factory in memoh_api_key_factories(settings, ctx) {
              if factory.provider_id() == id {
                let key = factory.login(auth_prompt)
                return @oauth.ProviderCredential::ApiKey(key)
              }
            }
          } else if auth_method == "oauth" {
            let device_id = if id == "kimi" {
              memoh_device_id(fs, home)
            } else {
              ""
            }
            for factory in memoh_oauth_factories(ctx, device_id~) {
              if factory.provider_id() == id {
                let oauth = factory.login(auth_interaction)
                return @oauth.ProviderCredential::OAuth(oauth)
              }
            }
          }
          raise @posoco.CommandError::InvalidArgs(
            reason="unsupported authentication method",
          )
        },
        requested=provider,
      )
      // Commit only after the shared flow has checked cancellation and
      // returned a complete, provider-owned credential.
      let store = @credentials.FileProviderCredentialStore(
        fs,
        credentials_path(home),
      )
      store.write(login.provider, login.credential) catch {
        _ =>
          raise @posoco.CommandError::ExecutionFailed(
            "Authentication completed, but credentials could not be saved",
          )
      }
      @stdio.stderr.write(
        @utf8.encode(
          "cetas-memoh: authentication saved for " +
          login.provider +
          "; restart the Memoh ACP runtime to use the updated credential.\n",
        )[:],
      )
    },
  )
}
