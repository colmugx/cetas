///|
/// Provider-owned tool planes for host composition.
///
/// A provider extension that ships tools (remote MCP servers, a vendor search
/// API) contributes them as its own dynamic tool group. Cetas-core is the one
/// place that already knows every provider (it registers the factories), so the
/// construction lives here instead of being copied into each host's assembly:
/// adding a provider capability changes this file only, and every host that
/// composes its session through `build_cetas_session` — or calls this helper
/// directly — picks it up without touching provider knowledge.
///
/// The two inputs core cannot invent are host-scoped: the session event bus and
/// the task group that outlives connections. Both are parameters, so a tool
/// plane never outlives the host that owns it.
///
/// Returns only the companions whose provider is actually configured: an
/// unconfigured provider contributes nothing (no empty group, no failed
/// connect at startup).

///|
pub async fn provider_tool_extensions(
  fs : &@workspace.WorkspaceFs,
  home~ : String,
  label~ : String = "cetas-acp",
  bus~ : @devkit.EventBus,
  group~ : @async.TaskGroup[Unit],
  initial_slot_id~ : String,
) -> Array[&@posoco.Extension] noraise {
  let exts : Array[&@posoco.Extension] = []
  // GLM Coding Plan: the plan's three official remote MCP servers.
  let zai_source = provider_config_source(
    fs,
    home~,
    provider_id=@zai_coding_plan.zai_coding_plan_provider_id(),
    label~,
  ) catch {
    _ => None
  }
  match zai_source {
    Some(source) => {
      // Same interpretation the model catalog used: one settings source, one
      // credential snapshot, no second opinion about the endpoint.
      let zai_config = @zai_coding_plan.zai_coding_plan_build_config(source) catch {
        _ => None
      }
      match zai_config {
        Some(config) =>
          exts.push(
            @zai_coding_plan.ZaiCodingPlanTools(
              config~,
              bus~,
              group~,
              initial_slot_id~,
            )
            as &@posoco.Extension,
          )
        None => ()
      }
    }
    None => ()
  }
  exts
}
