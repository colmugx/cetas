///|
/// provider_credential.mbt — Pure credential parsing and path helpers.
///
/// These functions decode the tagged provider-credential record and format
/// provider-neutral OAuth/AuthPrompt observer messages. They touch no IO: a
/// host reads the file (or mints a device id) and hands the parsed value to
/// these helpers, so the same parsing is shared by every target.

///|
/// Result of reading a host-owned settings or credential file. Missing is
/// intentionally distinct from Failed: only an absent optional source may be
/// treated as "not configured". Permission, directory, and other filesystem
/// failures must remain observable at the composition boundary.
pub(all) enum FileReadResult {
  Missing
  Content(String)
  Failed(String)
}

///|
/// Canonical credential path below the Cetas settings directory. The provider
/// id is the public canonical id returned by `ProviderFactory::provider_id`.
pub fn credential_path(cwd : String, provider_id : String) -> String {
  cwd + "/.cetas/credentials/" + provider_id + ".json"
}

///|
/// Legacy API-key sidecar path. It is read only during one-way migration to
/// the unified tagged store.
pub fn legacy_api_key_credential_path(
  cwd : String,
  provider_id : String,
) -> String {
  cwd + "/.cetas/credentials/" + provider_id + ".api-key.json"
}

///|
/// Convert the tagged credential to the shared ext-oauth persistence record.
pub fn provider_credential_to_json(
  credential : @oauth.ProviderCredential,
) -> Json {
  credential.to_json()
}

///|
/// Parse one tagged credential. `None` means the object has no method tag and
/// may therefore be a legacy OAuth record; malformed tagged records raise a
/// typed composition error without including secret values.
pub fn parse_tagged_provider_credential(
  json : Json,
  provider_id : String,
) -> @oauth.ProviderCredential? raise @posoco.CompositionError {
  match @oauth.ProviderCredential::from_json(json) {
    Some(value) => return Some(value)
    None => ()
  }
  let fields = match json {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas.credentials",
        detail="credential file must contain an object for provider " +
          provider_id,
      )
  }
  let kind = match fields.get("type") {
    None => return None
    Some(Json::String(value)) => value
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas.credentials",
        detail="credential type must be a string for provider " + provider_id,
      )
  }
  // Accept both flattened records (the current writer) and nested payloads
  // (the pre-release migration format), keeping the storage contract tolerant
  // without exposing provider-specific parsing to the host.
  let payload = match fields.get("credential") {
    Some(value) => value
    None => json
  }
  match kind {
    "oauth" =>
      match @oauth.Credential::from_json(payload) {
        Some(value) => Some(@oauth.ProviderCredential::OAuth(value))
        None =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="cetas.credentials",
            detail="credential file has an invalid OAuth shape for provider " +
              provider_id,
          )
      }
    "api_key" =>
      match @oauth.ApiKeyCredential::from_json(payload) {
        Some(value) => Some(@oauth.ProviderCredential::ApiKey(value))
        None =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="cetas.credentials",
            detail="credential file has an invalid API-key shape for provider " +
              provider_id,
          )
      }
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas.credentials",
        detail="credential file has an unsupported method for provider " +
          provider_id,
      )
  }
}

///|
/// Stable, secret-free summary of an OAuth error for diagnostics. Provider
/// details and token material never reach this string.
pub fn oauth_error_text(error : @oauth.OAuthError) -> String {
  match error {
    @oauth.OAuthError::AuthPending => "auth_pending"
    @oauth.OAuthError::SlowDown => "slow_down"
    @oauth.OAuthError::AccessDenied => "access_denied"
    @oauth.OAuthError::ExpiredToken => "expired_token"
    @oauth.OAuthError::InvalidGrant => "invalid_grant"
    @oauth.OAuthError::HttpError(detail) => "http_error: " + detail
    @oauth.OAuthError::ParseError(detail) => "parse_error: " + detail
    @oauth.OAuthError::Cancelled => "cancelled"
  }
}

///|
/// Encode an OAuth interaction message as a structured observer custom event.
/// The host renders it through its UI (TUI, web, headless) without the
/// provider knowing the UI library; the wire shape is stable across targets.
pub fn auth_message_json(message : @oauth.AuthMessage) -> String {
  let fields : Array[(String, Json)] = [
    ("type", Json::string("custom")),
    ("source", Json::string("cetas.oauth")),
  ]
  match message {
    @oauth.AuthMessage::AuthUrl(url) => {
      fields.push(("label", Json::string("auth_url")))
      fields.push(
        ("data", Json::object(Map::from_array([("url", Json::string(url))]))),
      )
    }
    @oauth.AuthMessage::DeviceCode(uri, code) => {
      fields.push(("label", Json::string("device_code")))
      fields.push(
        (
          "data",
          Json::object(
            Map::from_array([
              ("verification_uri", Json::string(uri)),
              ("user_code", Json::string(code)),
            ]),
          ),
        ),
      )
    }
    @oauth.AuthMessage::Progress(progress) => {
      fields.push(("label", Json::string("progress")))
      fields.push(
        (
          "data",
          Json::object(Map::from_array([("message", Json::string(progress))])),
        ),
      )
    }
  }
  Json::object(Map::from_array(fields)).stringify()
}

///|
/// Encode a provider-owned auth prompt (secret or select) as a structured
/// observer event. The host renders the prompt; secrets never pass through an
/// observer event and are never echoed.
pub fn auth_prompt_json(request : @oauth.AuthPromptRequest) -> String {
  match request {
    @oauth.AuthPromptRequest::Secret(message~) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("auth_prompt")),
          (
            "request",
            Json::object(
              Map::from_array([
                ("type", Json::string("secret")),
                ("message", Json::string(message)),
              ]),
            ),
          ),
        ]),
      ).stringify()
    @oauth.AuthPromptRequest::Select(message~, options~) => {
      let option_json : Array[Json] = []
      for option in options {
        let opt_fields : Array[(String, Json)] = [
          ("id", Json::string(option.id)),
          ("label", Json::string(option.label)),
        ]
        match option.description {
          Some(description) =>
            opt_fields.push(("description", Json::string(description)))
          None => ()
        }
        option_json.push(Json::object(Map::from_array(opt_fields)))
      }
      Json::object(
        Map::from_array([
          ("type", Json::string("auth_prompt")),
          (
            "request",
            Json::object(
              Map::from_array([
                ("type", Json::string("select")),
                ("message", Json::string(message)),
                ("options", Json::array(option_json)),
              ]),
            ),
          ),
        ]),
      ).stringify()
    }
  }
}
