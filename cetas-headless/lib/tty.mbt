///|
/// tty.mbt — the /dev/tty interactive bypass.
///
/// stdin is the pure task protocol (one line = one user turn), so every
/// human-facing prompt travels over a separate channel: the controlling
/// terminal, opened ssh-style via `@fs.open("/dev/tty")`. When no terminal
/// can be opened (pipes, CI, herdr panes without one) hosts degrade —
/// approval denies with a hint, UI requests raise Unsupported — instead of
/// ever touching stdin. All `TtyChannel` calls are noraise: a dead bypass
/// must never take the task protocol down.

///|
pub(all) struct TtyChannel {
  read_line : async () -> String? noraise
  write : async (String) -> Unit noraise
  close : () -> Unit
}

///|
pub async fn open_tty_channel() -> TtyChannel? noraise {
  let file : @fs.File = @fs.open("/dev/tty", mode=ReadWrite) catch {
    _ => return None
  }
  Some({
    read_line: async fn() noraise { file.read_until("\n") catch { _ => None } },
    write: async fn(text : String) noraise {
      // A failing tty write (terminal vanished mid-session) is swallowed:
      // the task protocol must stay alive even when the bypass is dead.
      file.write(text) catch {
        _ => ()
      }
    },
    close: fn() { file.close() },
  })
}
