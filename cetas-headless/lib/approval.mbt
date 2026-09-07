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

///|
/// The terminal plan review (`exit_plan_mode`'s boundary).
///
/// Mirrors the permission mapping; the plan decision set is Accept /
/// Revise(feedback) / Dismiss:
///
///   a / 1 → Accept          r / 2 → Revise(feedback read on the next line)
///   d / 3 / <empty> → Dismiss
///   anything else → re-prompt, EOF (either line) → Dismiss
///
/// Without a tty there is nobody to review, so the source prints the
/// unattended hint on its notice sink and dismisses — Dismiss is the only
/// decision that ends planning without granting edits, and Revise would
/// loop the model forever with no one to supply feedback.

///|
pub struct TerminalPlanReview {
  tty : TtyChannel?
  /// Degraded-path sink for the unattended hint (production: stderr).
  notice : async (String) -> Unit noraise
}

///|
pub fn TerminalPlanReview::TerminalPlanReview(
  tty~ : TtyChannel?,
  notice? : async (String) -> Unit noraise = fn(_ : String) { () },
) -> TerminalPlanReview {
  { tty, notice, }
}

///|
/// The exact one-line prompt rendered on the tty; long plans preview at 80 chars.
pub fn plan_review_prompt(request : @plan.PlanReviewRequest) -> String {
  let preview = if request.plan.length() <= 80 {
    request.plan
  } else {
    request.plan.sub(end=77).to_owned() + "..."
  }
  "[plan] \{preview} [a]pprove / [r]evise with feedback / [d]ismiss (default d): "
}

///|
/// What one option answer selects. None means "unrecognized" — the review
/// loop re-prompts. Comparison is trimmed and case-insensitive.
priv enum ReviewChoice {
  ChAccept
  ChRevise
  ChDismiss
}

///|
fn review_choice(input : String) -> ReviewChoice? {
  match input.trim().to_owned().to_lower() {
    "a" | "1" => Some(ChAccept)
    "r" | "2" => Some(ChRevise)
    "d" | "3" | "" => Some(ChDismiss)
    _ => None
  }
}

///|
pub impl @plan.PlanReviewSource for TerminalPlanReview with fn review(
  self : TerminalPlanReview,
  request : @plan.PlanReviewRequest,
) -> @plan.PlanReviewDecision {
  let tty = match self.tty {
    Some(tty) => tty
    None => {
      (self.notice)(
        "cetas-headless: a plan needs review but no terminal is available — dismissed (unattended, use --yolo)\n",
      )
      return @plan.PlanReviewDecision::Dismiss
    }
  }
  let prompt = plan_review_prompt(request)
  while true {
    (tty.write)(prompt)
    match (tty.read_line)() {
      None => return @plan.PlanReviewDecision::Dismiss
      Some(line) =>
        match review_choice(line) {
          Some(ChAccept) => return @plan.PlanReviewDecision::Accept
          Some(ChDismiss) => return @plan.PlanReviewDecision::Dismiss
          Some(ChRevise) => {
            (tty.write)(
              "feedback for the model (empty keeps planning with no note): ",
            )
            match (tty.read_line)() {
              None => return @plan.PlanReviewDecision::Dismiss
              Some(feedback) => {
                let note = feedback.trim().to_owned()
                return @plan.PlanReviewDecision::Revise(
                  feedback=if note.length() == 0 {
                    "The user chose to keep planning without a note. Ask what to change or refine the plan."
                  } else {
                    note
                  },
                )
              }
            }
          }
          None => (tty.write)("unrecognized answer; reply a, r, or d\n")
        }
    }
  } nobreak {
    // `while true` exits only via the returns above.
    abort("cetas-headless: plan review loop exited unexpectedly")
  }
}
