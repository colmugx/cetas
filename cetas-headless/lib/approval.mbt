///|
/// approval.mbt — the terminal approval source.
///
/// Permission prompts travel over the /dev/tty bypass; stdin stays the pure
/// task protocol. The decided mapping (cetas-headless-design §二):
///
///   y / 1 → AllowOnce        a / 2 → AllowSession
///   n / 3 / <empty> → Deny   s / 4 → Deny(reason="skipped")
///   anything else → re-prompt, EOF → Deny
///
/// Without a tty (pipes, CI) there is nobody to ask, so the source prints
/// the unattended hint on its notice sink and denies — the decided
/// degradation; `--yolo` avoids the round trip entirely by never asking.

///|
pub struct TerminalApprovalSource {
  tty : TtyChannel?
  /// Degraded-path sink for the unattended hint (production: stderr).
  notice : async (String) -> Unit noraise
}

///|
pub fn TerminalApprovalSource::TerminalApprovalSource(
  tty~ : TtyChannel?,
  notice? : async (String) -> Unit noraise = fn(_ : String) { () },
) -> TerminalApprovalSource {
  { tty, notice, }
}

///|
/// The exact one-line prompt rendered on the tty for every ask.
pub fn approval_prompt(request : @permission.ApprovalRequest) -> String {
  "[permission] \{request.tool_name} (\{request.category}): \{request.arguments_preview} [y]es/[a]lways/[n]o/[s]kip (default n): "
}

///|
/// Map one answer line onto a decision. None means "unrecognized" — the ask
/// loop re-prompts. Comparison is trimmed and case-insensitive.
pub fn approval_decision(input : String) -> @permission.ApprovalDecision? {
  let answer = input.trim().to_owned().to_lower()
  match answer {
    "y" | "1" => Some(@permission.ApprovalDecision::AllowOnce)
    "a" | "2" => Some(@permission.ApprovalDecision::AllowSession)
    "n" | "3" | "" =>
      Some(@permission.ApprovalDecision::Deny(reason="denied by user"))
    "s" | "4" => Some(@permission.ApprovalDecision::Deny(reason="skipped"))
    _ => None
  }
}

///|
pub impl @permission.ApprovalSource for TerminalApprovalSource with fn ask(
  self : TerminalApprovalSource,
  request : @permission.ApprovalRequest,
) -> @permission.ApprovalDecision {
  let tty = match self.tty {
    Some(tty) => tty
    None => {
      (self.notice)(
        "cetas-headless: approval needed for '\{request.tool_name}' but no terminal is available — denied (unattended, use --yolo)\n",
      )
      return @permission.ApprovalDecision::Deny(
        reason="denied: no terminal for approval (unattended, use --yolo)",
      )
    }
  }
  let prompt = approval_prompt(request)
  while true {
    (tty.write)(prompt)
    match (tty.read_line)() {
      None =>
        return @permission.ApprovalDecision::Deny(
          reason="denied: approval input closed",
        )
      Some(line) =>
        match approval_decision(line) {
          Some(decision) => return decision
          None => (tty.write)("unrecognized answer; reply y, a, n, or s\n")
        }
    }
  } nobreak {
    // `while true` exits only via the returns above.
    abort("cetas-headless: approval loop exited unexpectedly")
  }
}
