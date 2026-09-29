#!/usr/bin/env python3
import argparse, csv, pathlib, platform as host_platform, sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
CORE = ROOT / "cetas-core"
RECIPES = CORE / "recipes.csv"
PKG_TEMPLATE = CORE / "lib" / "moon.pkg.in"
PKG_OUT = CORE / "lib" / "moon.pkg"
MBT_OUT = CORE / "lib" / "recipe.generated.mbt"

CASES = {
    "read": '''      "read" =>
        exts.push(
          @read.ReadTools(freshness~, anchor=Some(anchor), fs=Some(ctx.fs))
          as &@posoco.Extension,
        )''',
    "write": '''      "write" =>
        exts.push(
          @write.WriteTools(freshness~, anchor=Some(anchor))
          as &@posoco.Extension,
        )''',
    "edit": '''      "edit" =>
        exts.push(
          @edit.EditTools(freshness~, anchor=Some(anchor)) as &@posoco.Extension,
        )''',
    "glob": '''      "glob" =>
        exts.push(@glob.GlobTools(anchor=Some(anchor)) as &@posoco.Extension)''',
    "grep": '''      "grep" =>
        exts.push(@grep.GrepTools(anchor=Some(anchor)) as &@posoco.Extension)''',
    "astgrep": '''      "astgrep" =>
        exts.push(
          @astgrep.AstGrepTools(anchor=Some(anchor)) as &@posoco.Extension,
        )''',
    "bash": '''      "bash" =>
        if compiled_target_os() == "unix" {
          exts.push(
            @bash.ShellTools(anchor=Some(anchor)) as &@posoco.Extension,
          )
        }''',
    "ps1": '''      "ps1" =>
        if compiled_target_os() == "windows" {
          episodic.push(
            @ps1.PowerShellTools(anchor=Some(anchor)) as &@posoco.Extension,
          )
        }''',
    "webfetch": '''      "webfetch" =>
        episodic.push(@webfetch.WebFetchTools() as &@posoco.Extension)''',
    "skills": '''      "skills" => {
        let skills = build_cetas_skills(ctx~) catch { _ => None }
        match skills {
          Some(skills) => exts.push(skills)
          None => ()
        }
      }''',
    "forme": '''      "forme" =>
        exts.push(
          @forme.Forme::Forme(host_note=host_help_note) as &@posoco.Extension,
        )''',
    "askquestion": '''      "askquestion" =>
        exts.push(@askquestion.AskQuestionTools() as &@posoco.Extension)''',
    "handoff": '''      "handoff" =>
        exts.push(
          @handoff.Handoff(
            cwd=ctx.cwd,
            store=@handoff.DefaultHandoffStore() as &@handoff.HandoffStore,
            probe=@handoff.HandoffWorkspaceState(ctx.cwd)
              as &@handoff.HandoffWorkspaceProbe,
            work_sources=[],
          )
          as &@posoco.Extension,
        )''',
    "nmem": '''      "nmem" => {
        let nmem = @nmem.NowledgeMem(
          source_app="cetas",
          transport=@nmem.HttpNmemTransport::HttpNmemTransport()
            as &@nmem.NmemTransport,
          mcp=@nmem.LazyNmemMcp::LazyNmemMcp() as &@nmem.NmemMcp,
          platform=@nmem.PlatformFs::PlatformFs() as &@nmem.NmemPlatform,
        )
        match nmem_group {
          Some(group) => nmem.attach(group)
          None => ()
        }
        episodic.push(nmem as &@posoco.Extension)
      }''',
    "obsidian": '''      "obsidian" => {
        let vault : String? = match obsidian_vault {
          Some(name) => Some(name)
          None =>
            match @env.get_env_var("CETAS_OBSIDIAN") {
              Some(value) if value != "on" && value != "1" && value != "off" =>
                Some(value)
              _ => None
            }
        }
        episodic.push(
          @obsidian.ObsidianTools::new(
            config=@obsidian.ObsidianConfig::ObsidianConfig(
              vault~,
              read_only=false,
            ),
          )
          as &@posoco.Extension,
        )
      }''',
    "lazytools": '''      "lazytools" => ()''',
}

def detect_platform() -> str:
    return "windows" if host_platform.system().lower().startswith("win") else "unix"

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--flavor", default="public", choices=["public", "personal"])
    ap.add_argument("--frontend", required=True, choices=["acp", "headless", "js"])
    ap.add_argument("--platform", choices=["unix", "windows"], default=detect_platform())
    args = ap.parse_args()

    with RECIPES.open(newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))

    selected = [
        row for row in rows
        if row["flavor"] == args.flavor
        and row["frontend"] == args.frontend
        and row["platform"] in ("any", args.platform)
    ]
    selected.sort(key=lambda row: int(row["order"]))
    if not selected:
        raise SystemExit(f"no recipe rows for {args.flavor}/{args.frontend}/{args.platform}")

    keys = [row["key"] for row in selected]
    if len(keys) != len(set(keys)):
        raise SystemExit("recipe contains duplicate feature keys")

    imports = []
    seen_imports = set()
    for row in selected:
        if row["scope"] != "core":
            continue
        entry = f'  "{row["package"]}" @{row["alias"]},'
        if entry not in seen_imports:
            seen_imports.add(entry)
            imports.append(entry)

    pkg = PKG_TEMPLATE.read_text(encoding="utf-8")
    pkg = pkg.replace("__RECIPE_IMPORTS__", "\n".join(imports))
    PKG_OUT.write_text(pkg, encoding="utf-8")

    recipe_items = "\n".join(f'  "{row["key"]}",' for row in selected)
    package_items = "\n".join(
        f'    ("{row["key"]}", "{row["package"]}"),' for row in selected
    )

    cases = []
    for row in selected:
        if row["scope"] != "core":
            continue
        key = row["key"]
        case = CASES.get(key)
        if case is None:
            raise SystemExit(f"no MoonBit constructor registered for core recipe key: {key}")
        cases.append(case)

    mbt = f'''///|
/// GENERATED by scripts/prepare-recipe.py — do not edit.
/// flavor={args.flavor} frontend={args.frontend} platform={args.platform}
let compiled_recipe : Array[String] = [
{recipe_items}
]

///|
let compiled_recipe_packages : Map[String, String] = Map::from_array([
{package_items}
])

///|
fn compiled_recipe_has(key : String) -> Bool {{
  match compiled_recipe_packages.get(key) {{
    Some(_) => true
    None => false
  }}
}}

///|
pub fn compiled_zcode_enabled() -> Bool {{
  compiled_recipe_has("zcode")
}}

///|
fn compiled_target_os() -> String {{
  "{args.platform}"
}}

///|
async fn build_compiled_recipe_features(
  ctx~ : HostContext,
  nmem_group? : @async.TaskGroup[Unit]? = None,
  host_help_note? : String? = None,
  obsidian_vault? : String? = None,
) -> Array[&@posoco.Extension] raise @posoco.CompositionError {{
  let _ = nmem_group
  let _ = obsidian_vault
  let exts : Array[&@posoco.Extension] = []
  let episodic : Array[&@posoco.Extension] = []
  let anchor = @devkit.WorkspaceAnchor::WorkspaceAnchor(ctx.cwd)
  let freshness = @devkit.FreshnessGuard::FreshnessGuard()

  for key in compiled_recipe {{
    match key {{
{chr(10).join(cases)}
      "zcode" => ()
      _ =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="cetas.recipe",
          detail="compiled recipe key has no constructor: " + key,
        )
    }}
  }}

  match compiled_recipe_packages.get("lazytools") {{
    Some(_) =>
      match @lazytools.LazyTools::defer_extensions(exts=episodic) {{
        Ok((gateway, views)) => {{
          for view in views {{
            exts.push(view)
          }}
          exts.push(gateway as &@posoco.Extension)
        }}
        Err(message) =>
          raise @posoco.CompositionError::ToolCollision(
            "deferred tool name collision",
            message,
            manifests=["cetas-core.default_features"],
          )
      }}
    None =>
      if !episodic.is_empty() {{
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="cetas.recipe",
          detail="recipe has episodic extensions but no lazytools entry",
        )
      }}
  }}
  exts
}}
'''
    MBT_OUT.write_text(mbt, encoding="utf-8")

    print(f"recipe: {args.flavor}/{args.frontend}/{args.platform}")
    for row in selected:
        print(f"  {row['order']:>3}  {row['key']:<12} {row['package']}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
