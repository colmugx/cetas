///|
/// peer.mbt — the herdr peer envelope (cetas-headless-design §二 建联协议).
///
/// A driver (herdr pane, script) prefixes a task line with the attribution
/// envelope `[cetas-peer from=<pane> session=<id>] <task>`. The task text is
/// what the agent is asked; the attribution is untrusted input and reaches
/// the model only inside a low-trust `herdr-peer` context envelope
/// (cetas-context trust grading) — peer-injected instructions cannot pose
/// as host or user authority. This is a security boundary, not a nicety.

///|
pub(all) struct PeerEnvelope {
  /// Sending pane name (`from=`).
  from : String
  /// Driver-declared peer session id (`session=`).
  session : String
  /// The task text after the envelope.
  task : String
}

///|
/// Parse the peer envelope prefix. Returns None for any line that does not
/// carry a well-formed envelope (including an empty `from`/`session`); such
/// lines stay plain tasks.
pub fn parse_peer_envelope(line : String) -> PeerEnvelope? {
  let open = "[cetas-peer from="
  if !line.has_prefix(open) {
    return None
  }
  let body = line.sub(start=open.length())
  let sep = " session="
  let sep_at = match body.find(sep) {
    None => return None
    Some(at) => at
  }
  let from = body.sub(end=sep_at).to_owned()
  if from == "" {
    return None
  }
  let tail = body.sub(start=sep_at + sep.length())
  let close = "] "
  let close_at = match tail.find(close) {
    None => return None
    Some(at) => at
  }
  let session = tail.sub(end=close_at).to_owned()
  if session == "" {
    return None
  }
  let task = tail
    .sub(start=close_at + close.length())
    .to_owned()
    .trim()
    .to_owned()
  Some({ from, session, task, })
}
