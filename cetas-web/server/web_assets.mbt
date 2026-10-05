///|
/// Production asset seam for cetas-web.
///
/// The bootstrap keeps this empty and serves `web/dist/client` from disk.
/// A follow-up packer will generate this map from Solid's static build so the
/// native host can ship as a single executable without a sidecar directory.
fn web_assets() -> Map[String, Bytes] {
  {}
}
