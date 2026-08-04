///|
/// provider_credential.mbt — Provider-neutral auth wire encoding.
///
/// The durable credential record codec and its file backend live in
/// `posoco-ext-credentials`; the filesystem boundary lives in
/// `posoco-ext-workspace`. What remains here is cetas's product wire shape:
/// secret-free error text and the observer-event JSON every cetas host
/// renders the same way.

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
