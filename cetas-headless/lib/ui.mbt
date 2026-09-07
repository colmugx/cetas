///|
/// ui.mbt — the terminal UI port (ask_question's three primitives).
///
/// Input/Confirm/Select are rendered on the /dev/tty bypass; `render` is a
/// no-op (headless has no persistent UI region — structured consumption
/// arrives with phase 3's `--jsonl`) and `ui_descriptor` is empty. Without
/// a tty — or under `--yolo`, where no port is attached at all — requests
/// raise `Unsupported`, which askquestion degrades from ("Interactive UI is
/// unavailable").

///|
pub struct TerminalUiPort {
  tty : TtyChannel?
}

///|
pub fn TerminalUiPort::TerminalUiPort(tty~ : TtyChannel?) -> TerminalUiPort {
  { tty, }
}

///|
pub impl @posoco.UiPort for TerminalUiPort with fn ui_descriptor(
  self : TerminalUiPort,
) -> @posoco.UiDescriptor {
  let _ = self
  @posoco.UiDescriptor::empty()
}

///|
pub impl @posoco.UiPort for TerminalUiPort with fn render(
  self : TerminalUiPort,
  intent : @posoco.UiRender,
) -> Unit {
  let _ = self
  let _ = intent
}

///|
/// Parse a Select menu answer into a 1-based number. None when the line is
/// not pure digits (the caller re-prompts).
fn parse_menu_choice(line : String) -> Int? {
  let trimmed = line.trim()
  if trimmed.length() == 0 {
    return None
  }
  let mut value = 0
  for ch in trimmed {
    match ch {
      '0' | '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9' => {
        let digit = ch.to_int() - '0'.to_int()
        value = value * 10 + digit
      }
      _ => return None
    }
  }
  Some(value)
}

///|
pub impl @posoco.UiPort for TerminalUiPort with fn request(
  self : TerminalUiPort,
  req : @posoco.UiRequest,
) -> @posoco.UiResponse raise @error.UiError {
  let tty = match self.tty {
    Some(tty) => tty
    None =>
      raise @error.UiError::Unsupported(
        detail="cetas-headless: interactive requests unavailable (no controlling terminal or --yolo)",
      )
  }
  match req {
    Input(prompt~, default~) => {
      (tty.write)("\{prompt}: ")
      match (tty.read_line)() {
        None => @posoco.UiResponse::Cancelled
        Some(line) =>
          // Free-form text is passed through verbatim; only a bare Enter
          // falls back to the advertised default.
          if line.trim().length() == 0 {
            match default {
              Some(value) => @posoco.UiResponse::Text(value)
              None => @posoco.UiResponse::Text(line)
            }
          } else {
            @posoco.UiResponse::Text(line)
          }
      }
    }
    Confirm(prompt~) =>
      while true {
        (tty.write)("\{prompt} [y/n]: ")
        match (tty.read_line)() {
          None => return @posoco.UiResponse::Cancelled
          Some(line) => {
            let answer = line.trim().to_owned().to_lower()
            if answer == "y" || answer == "yes" {
              return @posoco.UiResponse::Yes
            }
            if answer == "n" || answer == "no" || answer == "" {
              return @posoco.UiResponse::No
            }
            (tty.write)("unrecognized answer; reply y or n\n")
          }
        }
      } nobreak {
        // `while true` exits only via the returns above.
        abort("cetas-headless: confirm loop exited unexpectedly")
      }
    Select(prompt~, options~, default~) => {
      if options.is_empty() {
        raise @error.UiError::InvalidRequest(detail="select offered no options")
      }
      (tty.write)("\{prompt}\n")
      for i = 0; i < options.length(); i = i + 1 {
        (tty.write)("  [\{i + 1}] \{options[i]}\n")
      }
      while true {
        (tty.write)("choose 1-\{options.length()}")
        (tty.write)(
          match default {
            Some(d) => " (default \{d + 1})"
            None => ""
          },
        )
        (tty.write)(": ")
        match (tty.read_line)() {
          None => return @posoco.UiResponse::Cancelled
          Some(line) => {
            let accepted = match parse_menu_choice(line) {
              Some(n) =>
                if n >= 1 && n <= options.length() {
                  Some(n - 1)
                } else {
                  None
                }
              None => None
            }
            match accepted {
              Some(index) => return @posoco.UiResponse::Selected(index)
              None => {
                // A bare Enter accepts the advertised default, when given.
                let used_default = if line.trim().length() == 0 {
                  default
                } else {
                  None
                }
                match used_default {
                  Some(d) => return @posoco.UiResponse::Selected(d)
                  None => (tty.write)("choose a number 1-\{options.length()}\n")
                }
              }
            }
          }
        }
      } nobreak {
        // `while true` exits only via the returns above.
        abort("cetas-headless: select loop exited unexpectedly")
      }
    }
  }
}
