///|
/// tty_wbtest.mbt — the /dev/tty feasibility spike plus live-roundtrip probe.
///
/// Spike verdict contract: in a test environment a controlling terminal may
/// or may not exist, so the automated probe asserts only
/// "open succeeds AND write works" when a tty exists, or a clean failure
/// (an error value, not a crash/hang) when it does not. Reading is exercised
/// only under the env-gated live probe (a blocking read would hang the
/// suite); the mapping/re-prompt logic itself is covered by the injected
/// FakeTty in approval_wbtest.mbt / ui_wbtest.mbt.

///|
async test "spike: /dev/tty opens read-write and accepts writes, or fails cleanly" {
  let opened : Result[@fs.File, String] = Ok(
    @fs.open("/dev/tty", mode=ReadWrite),
  ) catch {
    error => Err(error.to_string())
  }
  match opened {
    Err(message) =>
      // No controlling terminal here: the failure must be an observable
      // error value — exactly what open_tty_channel turns into None.
      assert_true(message.length() > 0)
    Ok(file) => {
      // A real terminal: prove the write half lands on the fd. The read half
      // is deliberately not exercised here (it would block on user input).
      file.write("cetas-headless tty probe\n")
      file.close()
    }
  }
}

///|
/// open_tty_channel mirrors the raw spike: same open, wrapped as a channel.
/// In a no-tty environment it must return None (the degradation path), never
/// raise or hang; with a tty it yields a channel whose write works.
async test "spike: open_tty_channel degrades to None without a controlling terminal" {
  let channel = open_tty_channel()
  match channel {
    None =>
      // Degradation path: the host prints the unattended hint and denies.
      assert_true(true)
    Some(tty) => {
      (tty.write)("cetas-headless tty channel probe\n")
      (tty.close)()
      assert_true(true)
    }
  }
}

///|
/// Live roundtrip probe (never runs in CI): set CETAS_HEADLESS_TTY_PROBE=1
/// and run under a pty with a line fed to it, e.g.
///
///   (sleep 6; printf 'hello tty\n'; sleep 25) | script -q /tmp/ts.txt \
///     env CETAS_HEADLESS_TTY_PROBE=1 rtk moon test lib --target native
///
/// Proves open → write → read end-to-end over /dev/tty; any other
/// environment exits through the clean-degradation branches.
async test "spike: live /dev/tty roundtrip (only when CETAS_HEADLESS_TTY_PROBE=1)" {
  if @env.get_env_var("CETAS_HEADLESS_TTY_PROBE") != Some("1") {
    return
  }
  let tty = open_tty_channel()
  match tty {
    None => {
      assert_true(true)
      return
    }
    Some(tty) => {
      (tty.write)("cetas-headless tty probe — expect an echoed line: ")
      let line = (tty.read_line)()
      match line {
        Some(text) => {
          (tty.write)("probe read back: \{text}\n")
          assert_true(text.length() > 0)
        }
        None => {
          (tty.write)("probe read EOF\n")
          assert_true(true)
        }
      }
      (tty.close)()
    }
  }
}
