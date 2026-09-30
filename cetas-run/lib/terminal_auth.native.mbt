///|
/// Native-only: the task protocol's stdin is never an authentication input.
priv type TerminalAuthMode

///|
extern "C" fn terminal_auth_input_path() -> String = "cetas_auth_input_path"

///|
extern "C" fn terminal_auth_mode_new(fd : @types.Fd) -> TerminalAuthMode = "cetas_auth_mode_new"

///|
#borrow(mode)
extern "C" fn terminal_auth_mode_enter(mode : TerminalAuthMode) -> Bool = "cetas_auth_mode_enter"

///|
#borrow(mode)
extern "C" fn terminal_auth_mode_restore(mode : TerminalAuthMode) -> Bool = "cetas_auth_mode_restore"

///|
#borrow(mode)
extern "C" fn terminal_auth_mode_close(mode : TerminalAuthMode) -> Unit = "cetas_auth_mode_close"

///|
priv struct TerminalAuthInput {
  read_line : async () -> String?
  write : async (String) -> Unit
  begin_secret : () -> Unit raise
  end_secret : () -> Unit raise
  close : () -> Unit
}

///|
async fn open_terminal_auth_input() -> TerminalAuthInput {
  let file = @fs.open(terminal_auth_input_path(), mode=ReadWrite) catch {
    _ =>
      fail("login requires a controlling terminal; task stdin will not be read")
  }
  let mode = terminal_auth_mode_new(file.fd())
  let mut handed_off = false
  defer (if !handed_off {
    terminal_auth_mode_close(mode)
    file.close()
  })
  // CONIN$ is not an output console. All I/O still uses the async runtime.
  let output = if @async.platform is Windows {
    @fs.open("CONOUT$", mode=WriteOnly) catch {
      _ => fail("login requires a controlling output terminal")
    }
  } else {
    file
  }
  handed_off = true
  {
    read_line: async fn() { file.read_until("\n") },
    write: async fn(text) { output.write(text) },
    begin_secret: fn() raise {
      if !terminal_auth_mode_enter(mode) {
        fail("cannot securely disable terminal echo; login input refused")
      }
    },
    end_secret: fn() raise {
      if !terminal_auth_mode_restore(mode) {
        fail("cannot restore terminal mode")
      }
    },
    close: fn() {
      terminal_auth_mode_close(mode)
      if @async.platform is Windows {
        output.close()
      }
      file.close()
    },
  }
}

///|
priv struct TerminalAuth {
  input : TerminalAuthInput
  messages : @aqueue.Queue[String]
  prompts : @async.Mutex
  mut stopped : Bool
}

///|
impl @oauth.AuthInteraction for TerminalAuth with fn notify(self, message) {
  if self.stopped {
    return
  }
  let text = match message {
    AuthUrl(url) => "Open this URL to authenticate: \{url}\n"
    DeviceCode(url, code) => "Open \{url} and enter code: \{code}\n"
    Progress(text) => text + "\n"
  }
  // Unbounded try_put queues immediately; it never waits for stderr.
  ignore(self.messages.try_put(text)) catch {
    _ => ()
  }
}

///|
impl @oauth.AuthInteraction for TerminalAuth with fn is_cancelled(self) {
  self.stopped || @async.is_being_cancelled()
}

///|
async fn TerminalAuth::line(
  self : TerminalAuth,
) -> String raise @oauth.OAuthError {
  let line = (self.input.read_line)() catch {
    _ => {
      self.stopped = true
      raise @oauth.OAuthError::ParseError(
        "terminal authentication input failed",
      )
    }
  }
  match line {
    Some(text) => text.trim_end(chars="\r\n").to_owned()
    None => {
      self.stopped = true
      raise @oauth.OAuthError::Cancelled
    }
  }
}

///|
impl @oauth.AuthPromptInteraction for TerminalAuth with fn prompt(self, request) {
  self.prompts.acquire()
  defer self.prompts.release()
  if self.stopped || @async.is_being_cancelled() {
    raise @oauth.OAuthError::Cancelled
  }
  try {
    match request {
      Secret(message~) => {
        // Install cleanup BEFORE entering: even a partially successful mode
        // change must be undone. Do not print/trim/interpolate the answer.
        defer (self.input.end_secret)()
        (self.input.begin_secret)()
        (self.input.write)(message + ": ")
        let answer = self.line()
        (self.input.write)("\n")
        answer
      }
      Select(message~, options~) => {
        if options.is_empty() {
          raise @oauth.OAuthError::ParseError(
            "authentication selection has no options",
          )
        }
        (self.input.write)(message + "\n")
        for i, option in options {
          let description = match option.description {
            Some(text) => " — " + text
            None => ""
          }
          (self.input.write)("  \{i + 1}. \{option.label}\{description}\n")
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
    error => {
      self.stopped = true
      match error {
        @oauth.OAuthError::Cancelled => raise @oauth.OAuthError::Cancelled
        _ =>
          raise @oauth.OAuthError::ParseError(
            "secure terminal authentication prompt failed",
          )
      }
    }
  }
}

///|
/// The injectable scope is also used by the hermetic prompt/pump tests.
async fn with_terminal_auth_input(
  input : TerminalAuthInput,
  note~ : async (String) -> Unit noraise,
  body~ : async (&@oauth.AuthInteraction, &@oauth.AuthPromptInteraction) -> Unit,
) -> Unit {
  defer (input.close)()
  let auth = {
    input,
    messages: @aqueue.Queue(kind=Unbounded),
    prompts: @async.Mutex(),
    stopped: false,
  }
  defer {
    auth.stopped = true
  }
  @async.with_task_group() <| group => {
    // Error/cancellation also drains queued notifications after the pump has
    // stopped. Bound cleanup so a broken stderr cannot prevent mode cleanup.
    group.add_defer(() => {
      auth.stopped = true
      auth.messages.close()
      @async.protect_from_cancel(() => {
        @async.with_timeout(2000, () => {
          while auth.messages.try_get() is Some(text) {
            note(text)
          }
        }) catch {
          _ => ()
        }
      })
    })
    group.spawn_bg(() => {
      while true {
        let text = auth.messages.get() catch {
          @aqueue.QueueAlreadyClosed => return
          error => raise error
        }
        // A dequeued message cannot be lost halfway through cancellation.
        @async.protect_from_cancel(() => {
          @async.with_timeout(2000, () => note(text)) catch {
            _ => ()
          }
        })
      }
    })
    defer {
      auth.stopped = true
      auth.messages.close()
    }
    body(auth, auth)
  }
}

///|
async fn with_terminal_auth(
  note~ : async (String) -> Unit noraise,
  body~ : async (&@oauth.AuthInteraction, &@oauth.AuthPromptInteraction) -> Unit,
) -> Unit {
  let input = open_terminal_auth_input()
  with_terminal_auth_input(input, note~, body~)
}
