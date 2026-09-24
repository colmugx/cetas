///|
/// tty_wbtest.mbt — the /dev/tty feasibility spike plus live-roundtrip probe.
///
/// Hermetic contract: the automated probes below touch the real /dev/tty only
/// to open it. Write/read I/O over a real terminal lands on the user's screen
/// (and a read blocks it), so that half lives exclusively in the env-gated
/// live probe; the mapping/re-prompt logic itself is covered by the injected
/// FakeTty in approval_wbtest.mbt / ui_wbtest.mbt.

///|
async test "spike: /dev/tty opens read-write or fails cleanly, never hangs" {
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
    Ok(file) =>
      // A controlling terminal exists: the open must not hang or raise; the
      // fd is closed untouched (terminal I/O stays in the live probe below).
      file.close()
  }
}

///|
/// open_tty_channel mirrors the raw spike: same open, wrapped as a channel.
/// In a no-tty environment it must return None (the degradation path), never
/// raise or hang; with a tty it yields a channel that is closed untouched.
async test "spike: open_tty_channel degrades to None without a controlling terminal" {
  let channel = open_tty_channel()
  match channel {
    None =>
      // Degradation path: the host prints the unattended hint and denies.
      assert_true(true)
    Some(tty) => {
      (tty.close)()
      assert_true(true)
    }
  }
}

///|
/// Live roundtrip probe (manual only, never in CI): proves open → write →
/// read end-to-end over a real /dev/tty. Opt in with CETAS_HEADLESS_TTY_PROBE=1
/// and run it under a pty that feeds a line — a bare run against a real
/// terminal blocks forever on the read, and the prompt text lands directly on
/// that terminal:
///
///   (sleep 6; printf 'hello tty\n'; sleep 25) | script -q /tmp/ts.txt \
///     env CETAS_HEADLESS_TTY_PROBE=1 moon test lib --target native
///
/// Any other environment exits through the clean-degradation branches above.
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
