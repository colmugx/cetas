/// Cross-host parity harness.
///
/// Input: one observer JSON payload per line on stdin.
/// Output: one normalized NativeShell snapshot JSON object on stdout.

///|
extern "C" fn exit(code : Int) = "exit"

///|
async fn main {
  let shell = @app.NativeShell::new()

  while true {
    let next = @stdio.stdin.read_until("\n") catch {
      _ => None
    }
    match next {
      None => break
      Some(line) => {
        let raw = line.trim()
        if !raw.is_empty() && !shell.handle_event_json(raw.to_owned()) {
          @stdio.stderr.write(
            "cetas-tui parity: malformed observer event: " +
            raw.to_owned() +
            "\n",
          ) catch {
            _ => ()
          }
          exit(2)
          abort("unreachable after exit")
        }
      }
    }
  }

  @stdio.stdout.write(shell.snapshot_json().stringify() + "\n")
}
