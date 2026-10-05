/// Native OAuth / provider-auth presentation.
///
/// Provider authentication stays toolkit-neutral through Posoco's
/// AuthInteraction/AuthPromptInteraction traits. This adapter maps those
/// interactions onto the same NativeUiPort that already serves extension UI
/// requests, keeping login inside the Ratatui event loop.

///|
pub struct NativeAuthUi {
  ui : NativeUiPort
  mut cancelled : Bool
}

///|
pub fn NativeAuthUi::new(ui : NativeUiPort) -> NativeAuthUi {
  { ui, cancelled: false, }
}

///|
pub fn NativeAuthUi::cancel(self : NativeAuthUi) -> Unit {
  self.cancelled = true
}

///|
fn auth_notice(
  ui : NativeUiPort,
  key : String,
  title : String,
  lines : Array[String],
) -> Unit {
  ui.render(
    @posoco.UiRender::{
      slot: @posoco.UiSlot::Notice,
      key,
      title: Some(title),
      body: @posoco.UiBody::Lines(lines),
      ttl_ms: None,
    },
  )
}

///|
pub impl @oauth.AuthInteraction for NativeAuthUi with fn notify(
  self : NativeAuthUi,
  message : @oauth.AuthMessage,
) -> Unit {
  if self.cancelled {
    return
  }
  match message {
    @oauth.AuthMessage::AuthUrl(url) =>
      auth_notice(
        self.ui,
        "oauth",
        "OAuth",
        ["Open this URL to authenticate:", url],
      )
    @oauth.AuthMessage::DeviceCode(uri, code) =>
      auth_notice(
        self.ui,
        "oauth",
        "OAuth device login",
        ["Open:", uri, "Code: " + code],
      )
    @oauth.AuthMessage::Progress(message) =>
      self.ui.render(
        @posoco.UiRender::{
          slot: @posoco.UiSlot::Status,
          key: "oauth",
          title: None,
          body: @posoco.UiBody::Text(message),
          ttl_ms: None,
        },
      )
  }
}

///|
pub impl @oauth.AuthInteraction for NativeAuthUi with fn is_cancelled(
  self : NativeAuthUi,
) -> Bool {
  self.cancelled || @async.is_being_cancelled()
}

///|
pub impl @oauth.AuthPromptInteraction for NativeAuthUi with fn prompt(
  self : NativeAuthUi,
  request : @oauth.AuthPromptRequest,
) -> String raise @oauth.OAuthError {
  if self.cancelled || @async.is_being_cancelled() {
    raise @oauth.OAuthError::Cancelled
  }
  match request {
    @oauth.AuthPromptRequest::Secret(message~) => {
      let response = (self.ui as &@posoco.UiPort).request(
        @posoco.UiRequest::Input(
          prompt=native_secret_prompt(message),
          default=None,
        ),
      ) catch {
        _ => raise @oauth.OAuthError::Cancelled
      }
      match response {
        @posoco.UiResponse::Text(value) => value
        _ => raise @oauth.OAuthError::Cancelled
      }
    }
    @oauth.AuthPromptRequest::Select(message~, options~) => {
      if options.is_empty() {
        raise @oauth.OAuthError::ParseError(
          "authentication selection has no options",
        )
      }
      let labels : Array[String] = []
      for option in options {
        let suffix = match option.description {
          Some(description) if !description.is_empty() =>
            " — " + description
          _ => ""
        }
        labels.push(option.label + suffix)
      }
      let response = (self.ui as &@posoco.UiPort).request(
        @posoco.UiRequest::Select(
          prompt=message,
          options=labels,
          default=Some(0),
        ),
      ) catch {
        _ => raise @oauth.OAuthError::Cancelled
      }
      match response {
        @posoco.UiResponse::Selected(index) if index >= 0 && index < options.length() =>
          options[index].id
        _ => raise @oauth.OAuthError::Cancelled
      }
    }
  }
}

///|
pub extend NativeAuthUi with @oauth.AuthInteraction::{notify, is_cancelled}

///|
pub extend NativeAuthUi with @oauth.AuthPromptInteraction::{prompt}
