///|
/// Trusted setup input. ACP stdio is protocol-only, so bootstrap secrets must
/// come from the controlling terminal and never from stdin or argv.
priv type MemohTerminalMode

///|
extern "C" fn memoh_terminal_mode_new(fd : @types.Fd) -> MemohTerminalMode = "cetas_memoh_auth_mode_new"

///|
#borrow(mode)
extern "C" fn memoh_terminal_mode_enter(mode : MemohTerminalMode) -> Bool = "cetas_memoh_auth_mode_enter"

///|
#borrow(mode)
extern "C" fn memoh_terminal_mode_restore(mode : MemohTerminalMode) -> Bool = "cetas_memoh_auth_mode_restore"

///|
#borrow(mode)
extern "C" fn memoh_terminal_mode_close(mode : MemohTerminalMode) -> Unit = "cetas_memoh_auth_mode_close"

///|
priv struct SetupTerminalInput {
  read_line : async () -> String?
  write : async (String) -> Unit
  begin_secret : () -> Unit raise
  end_secret : () -> Unit raise
  close : () -> Unit
}

///|
async fn open_setup_terminal() -> SetupTerminalInput {
  let file = @fs.open("/dev/tty", mode=ReadWrite) catch {
    _ =>
      fail(
        "setup requires a controlling terminal; ACP stdin is never used for credentials",
      )
  }
  let mode = memoh_terminal_mode_new(file.fd())
  let mut handed_off = false
  defer (if !handed_off {
    memoh_terminal_mode_close(mode)
    file.close()
  })
  handed_off = true
  {
    read_line: async fn() { file.read_until("\n") },
    write: async fn(text) { file.write(text) },
    begin_secret: fn() raise {
      if !memoh_terminal_mode_enter(mode) {
        fail("cannot securely disable terminal echo; credential input refused")
      }
    },
    end_secret: fn() raise {
      if !memoh_terminal_mode_restore(mode) {
        fail("cannot restore terminal mode")
      }
    },
    close: fn() {
      memoh_terminal_mode_close(mode)
      file.close()
    },
  }
}

///|
priv struct SetupPrompt {
  input : SetupTerminalInput
}

///|
async fn SetupPrompt::line(
  self : SetupPrompt,
) -> String raise @oauth.OAuthError {
  let line = (self.input.read_line)() catch {
    _ => raise @oauth.OAuthError::ParseError("terminal setup input failed")
  }
  match line {
    Some(text) => text.trim_end(chars="\r\n").to_owned()
    None => raise @oauth.OAuthError::Cancelled
  }
}

///|
impl @oauth.AuthPromptInteraction for SetupPrompt with fn prompt(
  self : SetupPrompt,
  request : @oauth.AuthPromptRequest,
) -> String {
  try {
    match request {
      Secret(message~) => {
        // Cleanup is installed before echo is disabled so every error path
        // restores the controlling terminal before it escapes this boundary.
        defer (self.input.end_secret)()
        (self.input.begin_secret)()
        (self.input.write)(message + ": ")
        let answer = self.line()
        (self.input.write)("\n")
        answer
      }
      Select(message~, options~) => {
        if options.is_empty() {
          raise @oauth.OAuthError::ParseError("setup selection has no options")
        }
        (self.input.write)(message + "\n")
        for i, option in options {
          let description = match option.description {
            Some(text) => " — " + text
            None => ""
          }
          (self.input.write)(
            "  " +
            (i + 1).to_string() +
            ". " +
            option.label +
            description +
            "\n",
          )
        }
        while true {
          (self.input.write)("Choose a number: ")
          let answer = self.line().trim().to_owned()
          for i, option in options {
            if answer == (i + 1).to_string() {
              return option.id
            }
          }
          (self.input.write)("Invalid selection; choose a listed number.\n")
        }
        abort("unreachable")
      }
    }
  } catch {
    error =>
      match error {
        @oauth.OAuthError::Cancelled => raise @oauth.OAuthError::Cancelled
        @oauth.OAuthError::ParseError(detail) =>
          raise @oauth.OAuthError::ParseError(detail)
        _ =>
          raise @oauth.OAuthError::ParseError(
            "secure terminal setup prompt failed",
          )
      }
  }
}

///|
async fn with_setup_prompt(
  body : async (&@oauth.AuthPromptInteraction) -> String,
) -> String {
  let input = open_setup_terminal()
  defer (input.close)()
  let prompt = SetupPrompt::{ input, }
  body(prompt)
}
