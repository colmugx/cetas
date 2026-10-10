///|
fn readings_json(readings : Array[@devkit.QuotaReading]) -> Array[Json] {
  let out : Array[Json] = []
  for reading in readings {
    let used_percent : Json = match reading.used_percent {
      Some(percent) => Json::number(percent)
      None => Json::null()
    }
    let amount : Json = match reading.amount {
      Some((value, currency)) =>
        Json::object(
          Map::from_array([
            ("value", Json::string(value)),
            ("currency", Json::string(currency)),
          ]),
        )
      None => Json::null()
    }
    let available : Json = match reading.available {
      Some(flag) => Json::boolean(flag)
      None => Json::null()
    }
    out.push(
      Json::object(
        Map::from_array([
          ("window", Json::string(reading.window)),
          ("used_percent", used_percent),
          ("amount", amount),
          ("available", available),
          ("fetched_at_ms", Json::number(reading.fetched_at_ms.to_double())),
        ]),
      ),
    )
  }
  out
}

///|
/// Pull-style quota read for the ACTIVE provider — the web mirror of the
/// `/status` command: look the active provider id up in the quota registry
/// at request time and read the source live. No provider branches here:
/// readings are shaped entirely by the pushed data (windows carry
/// used_percent, balance-style sources carry amount+currency).
pub async fn ConsoleRuntime::quota_json(self : ConsoleRuntime) -> Json {
  let handle = self.active().active()
  let provider_id = handle.router.current_provider_id()
  let readings : Array[Json] = match
    @devkit.quota_registry_lookup(provider_id) {
    Some(source) =>
      match source.read() {
        Ok(list) => readings_json(list)
        Err(_) => []
      }
    None => []
  }
  Json::object(
    Map::from_array([
      ("provider", Json::string(provider_id)),
      ("session_id", Json::string(handle.session_id)),
      ("readings", Json::array(readings)),
    ]),
  )
}

///|
/// Every distinct slot provider with a registered quota source, read live —
/// powers the expanded multi-provider view. Slow sources only delay this
/// payload; the active-provider event goes out first.
pub async fn ConsoleRuntime::quota_all_json(self : ConsoleRuntime) -> Json {
  let handle = self.active().active()
  let seen : Map[String, Bool] = Map::from_array([])
  let providers : Array[Json] = []
  for slot in handle.router.list_slots() {
    if !seen.contains(slot.provider_id) {
      seen[slot.provider_id] = true
      match @devkit.quota_registry_lookup(slot.provider_id) {
        Some(source) =>
          match source.read() {
            Ok(list) =>
              providers.push(
                Json::object(
                  Map::from_array([
                    ("provider", Json::string(slot.provider_id)),
                    ("readings", Json::array(readings_json(list))),
                  ]),
                ),
              )
            Err(_) => ()
          }
        None => ()
      }
    }
  }
  Json::object(Map::from_array([("providers", Json::array(providers))]))
}
