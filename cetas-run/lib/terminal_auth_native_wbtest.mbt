///|
priv struct AuthTerminalFake {
  lines : Array[String?]
  writes : Array[String]
  events : Array[String]
  mut echo : Bool
  mut refuse : Bool
  mut wait : Bool
}

///|
fn auth_terminal_fake(lines : Array[String?]) -> AuthTerminalFake {
  { lines, writes: [], events: [], echo: true, refuse: false, wait: false, }
}

///|
fn AuthTerminalFake::input(self : AuthTerminalFake) -> TerminalAuthInput {
  {
    read_line: async fn() {
      self.events.push("read")
      if self.wait {
        @async.sleep(60000)
      }
      if self.lines.is_empty() {
        None
      } else {
        self.lines.remove(0)
      }
    },
    write: fn(text) { self.writes.push(text) },
    begin_secret: fn() raise {
      self.events.push("suppress")
      if self.refuse {
        fail("native failure must not be forwarded")
      }
      self.echo = false
    },
    end_secret: fn() {
      self.events.push("restore")
      self.echo = true
    },
    close: fn() { self.events.push("close") },
  }
}

///|
async test "terminal auth: select maps option IDs and rejects invalid input without printing it" {
  let fake = auth_terminal_fake([Some("do-not-log-this"), Some("2\r\n")])
  with_terminal_auth_input(fake.input(), note=fn(_) {  }, body=async fn(
    _,
    prompt,
  ) {
    let answer = prompt.prompt(
      @oauth.AuthPromptRequest::Select(message="Choose login", options=[
        @oauth.AuthPromptOption(id="first", label="First"),
        @oauth.AuthPromptOption(
          id="second",
          label="Second",
          description=Some("details"),
        ),
      ]),
    )
    assert_eq(answer, "second")
  })
  assert_false(fake.writes.join("").contains("do-not-log-this"))
  assert_true(fake.writes.join("").contains("2. Second — details"))
  assert_eq(fake.events, ["read", "read", "close"])
}

///|
async test "terminal auth: secret keeps whitespace, never prints answer, restores then closes" {
  let fake = auth_terminal_fake([Some("  synthetic-secret  \r\n")])
  with_terminal_auth_input(fake.input(), note=fn(_) {  }, body=async fn(
    _,
    prompt,
  ) {
    let answer = prompt.prompt(
      @oauth.AuthPromptRequest::Secret(message="API key"),
    )
    assert_eq(answer, "  synthetic-secret  ")
    assert_true(fake.echo)
  })
  assert_eq(fake.events, ["suppress", "read", "restore", "close"])
  assert_eq(fake.writes, ["API key: ", "\n"])
}

///|
async test "terminal auth: echo suppression failure refuses input and sanitizes errors" {
  let fake = auth_terminal_fake([Some("not-read")])
  fake.refuse = true
  with_terminal_auth_input(fake.input(), note=fn(_) {  }, body=async fn(
    auth,
    prompt,
  ) {
    let failed = try {
      ignore(prompt.prompt(@oauth.AuthPromptRequest::Secret(message="Key")))
      false
    } catch {
      @oauth.OAuthError::ParseError(message) => {
        assert_eq(message, "secure terminal authentication prompt failed")
        true
      }
      _ => fail("expected sanitized prompt error")
    }
    assert_true(failed)
    assert_true(auth.is_cancelled())
  })
  assert_eq(fake.events, ["suppress", "restore", "close"])
  assert_eq(fake.writes, [])
}

///|
async test "terminal auth: secret EOF cancels the lifecycle and restores echo" {
  let fake = auth_terminal_fake([None])
  with_terminal_auth_input(fake.input(), note=fn(_) {  }, body=async fn(
    auth,
    prompt,
  ) {
    let cancelled = try {
      ignore(prompt.prompt(@oauth.AuthPromptRequest::Secret(message="Key")))
      false
    } catch {
      @oauth.OAuthError::Cancelled => true
      _ => fail("expected EOF cancellation")
    }
    assert_true(cancelled)
    assert_true(auth.is_cancelled())
  })
  assert_true(fake.echo)
  assert_eq(fake.events, ["suppress", "read", "restore", "close"])
}

///|
async test "terminal auth: notifications are synchronous queued and pumped during wait, then drained" {
  let fake = auth_terminal_fake([])
  let notes : Array[String] = []
  let retained : Array[&@oauth.AuthInteraction] = []
  with_terminal_auth_input(
    fake.input(),
    note=async fn(text) noraise {
      @async.sleep(1)
      notes.push(text)
    },
    body=async fn(auth, _) {
      retained.push(auth)
      auth.notify(@oauth.AuthMessage::AuthUrl("https://example.invalid/login"))
      auth.notify(
        @oauth.AuthMessage::DeviceCode(
          "https://example.invalid/device", "SYNTHETIC",
        ),
      )
      auth.notify(@oauth.AuthMessage::Progress("waiting"))
      @async.sleep(20)
      assert_eq(notes.length(), 3)
      auth.notify(@oauth.AuthMessage::Progress("done"))
    },
  )
  assert_eq(notes, [
    "Open this URL to authenticate: https://example.invalid/login\n", "Open https://example.invalid/device and enter code: SYNTHETIC\n",
    "waiting\n", "done\n",
  ])
  assert_true(retained[0].is_cancelled())
  retained[0].notify(@oauth.AuthMessage::Progress("late"))
  assert_eq(notes.length(), 4)
}

///|
async test "terminal auth: body errors drain notifications and close" {
  let fake = auth_terminal_fake([])
  let notes : Array[String] = []
  let failed = try {
    with_terminal_auth_input(fake.input(), note=fn(text) { notes.push(text) }, body=fn(
      auth,
      _,
    ) raise {
      auth.notify(@oauth.AuthMessage::Progress("one"))
      auth.notify(@oauth.AuthMessage::Progress("two"))
      fail("synthetic body failure")
    })
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  assert_eq(notes, ["one\n", "two\n"])
  assert_eq(fake.events, ["close"])
}

///|
async test "terminal auth: cancellation restores mode and drains pending notifications" {
  let fake = auth_terminal_fake([])
  fake.wait = true
  let notes : Array[String] = []
  let retained : Array[&@oauth.AuthInteraction] = []
  @async.with_task_group() <| group => {
    let task = group.spawn(
      () => {
        with_terminal_auth_input(
          fake.input(),
          note=async fn(text) noraise {
            @async.sleep(50)
            notes.push(text)
          },
          body=async fn(auth, prompt) {
            retained.push(auth)
            auth.notify(@oauth.AuthMessage::Progress("before cancel"))
            auth.notify(@oauth.AuthMessage::Progress("pending one"))
            auth.notify(@oauth.AuthMessage::Progress("pending two"))
            ignore(
              prompt.prompt(@oauth.AuthPromptRequest::Secret(message="Key")),
            )
          },
        )
      },
      allow_failure=true,
    )
    @async.sleep(20)
    task.cancel()
  }
  assert_true(fake.echo)
  assert_eq(fake.events, ["suppress", "read", "restore", "close"])
  assert_eq(notes, ["before cancel\n", "pending one\n", "pending two\n"])
  assert_true(retained[0].is_cancelled())
}

///|
extern "C" fn terminal_auth_test_snapshot(fd : @types.Fd) -> Bytes = "cetas_auth_test_snapshot"

///|
async test "terminal auth: controlling terminal opens or fails before calling body" {
  let called = Ref(false)
  with_terminal_auth(note=fn(_) {  }, body=fn(_, _) { called.val = true }) catch {
    error => {
      assert_false(called.val)
      assert_true(error.to_string().contains("controlling terminal"))
    }
  }
}

///|
/// Opt-in only: run on an isolated PTY, never on the developer's terminal.
/// Automation waits for AUTH_PTY_KEY before sending synthetic input / EOF /
/// Ctrl+C. AUTH_MODE_RESTORED is emitted even during global cancellation.
async test "terminal auth: isolated PTY mode restoration" {
  guard @env.get_env_var("CETAS_RUN_AUTH_PTY_CASE") is Some(which) else {
    return
  }
  let observer = @fs.open(terminal_auth_input_path(), mode=ReadWrite)
  defer observer.close()
  let before = terminal_auth_test_snapshot(observer.fd())
  assert_true(before.length() > 0)
  defer {
    assert_eq(terminal_auth_test_snapshot(observer.fd()), before)
    println("AUTH_MODE_RESTORED")
  }
  let failed = try {
    with_terminal_auth(
      note=async fn(text) noraise {
        @stdio.stderr.write(text) catch {
          _ => ()
        }
      },
      body=async fn(auth, prompt) {
        auth.notify(@oauth.AuthMessage::Progress("AUTH_PUMP_VISIBLE"))
        let answer = prompt.prompt(
          @oauth.AuthPromptRequest::Secret(message="AUTH_PTY_KEY"),
        )
        // Never use an assertion which includes the answer in a diagnostic.
        assert_true(answer == "synthetic-native-secret")
        if which == "error" {
          fail("synthetic body error")
        }
      },
    )
    false
  } catch {
    _ => true
  }
  if which == "success" {
    assert_false(failed)
  } else {
    assert_true(failed)
  }
}

///|
async test "terminal auth: native guard refuses a non-terminal and closes idempotently" {
  let dir = @fs.tmpdir(prefix="cetas-auth-mode-test")
  defer @fs.rmdir(dir, recursive=true)
  let file = @fs.create(dir + "/not-a-terminal")
  defer file.close()
  let mode = terminal_auth_mode_new(file.fd())
  defer terminal_auth_mode_close(mode)
  assert_false(terminal_auth_mode_enter(mode))
  assert_true(terminal_auth_mode_restore(mode))
  terminal_auth_mode_close(mode)
  assert_false(terminal_auth_mode_enter(mode))
  // The guard owns only its duplicate, not the runtime's original handle.
  file.write("still open")
}
