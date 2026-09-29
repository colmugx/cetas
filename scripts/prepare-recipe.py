#!/usr/bin/env python3
import argparse, csv, os, pathlib, platform as host_platform, sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
CORE = ROOT / "cetas-core"
BASE_RECIPES = CORE / "recipes.csv"
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
    "shell": '''      "shell" =>
        for shell in build_cetas_tools(ctx~, ["bash"]) {
          exts.push(shell)
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

RECIPE_FIELDS = [
    "section", "flavor", "frontend", "order", "key", "scope",
    "package", "alias", "platform", "runtime_key",
]

def detect_platform() -> str:
    return "windows" if host_platform.system().lower().startswith("win") else "unix"

def resolve_recipe_path(value: str) -> pathlib.Path:
    path = pathlib.Path(value).expanduser()
    if not path.is_absolute():
        path = ROOT / path
    return path

def read_recipe_rows(path: pathlib.Path) -> list[dict[str, str]]:
    if not path.is_file():
        raise SystemExit(f"recipe file not found: {path}")
    with path.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != RECIPE_FIELDS:
            raise SystemExit(
                f"recipe file {path} must have header: {','.join(RECIPE_FIELDS)}"
            )
        return list(reader)

def load_recipe_rows(extra_overlays: list[str]) -> tuple[list[dict[str, str]], list[pathlib.Path]]:
    sources = [BASE_RECIPES]
    env_overlay = os.environ.get("CETAS_RECIPE_OVERLAY", "").strip()
    if env_overlay:
        sources.append(resolve_recipe_path(env_overlay))
    sources.extend(resolve_recipe_path(value) for value in extra_overlays)

    merged: dict[tuple[str, str, str, str], dict[str, str]] = {}
    for source in sources:
        for row in read_recipe_rows(source):
            identity = (
                row["flavor"],
                row["frontend"],
                row["key"],
                row["platform"],
            )
            merged[identity] = row
    return list(merged.values()), sources

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--flavor", default=os.environ.get("CETAS_FLAVOR", "public"))
    ap.add_argument("--frontend", required=True, choices=["acp", "run", "js", "all", "all-native", "all-js"])
    ap.add_argument("--platform", choices=["unix", "windows"], default=detect_platform())
    ap.add_argument(
        "--recipe-overlay",
        action="append",
        default=[],
        help=(
            "additional recipe CSV; later rows override matching "
            "(flavor,frontend,key,platform) entries. "
            "CETAS_RECIPE_OVERLAY provides one local overlay path."
        ),
    )
    args = ap.parse_args()

    rows, sources = load_recipe_rows(args.recipe_overlay)
    valid_flavors = sorted({
        row["flavor"]
        for row in rows
        if row["section"] == "special" and row["flavor"] != "*"
    })
    if args.flavor != "all" and args.flavor not in valid_flavors and args.flavor != "public":
        raise SystemExit(
            "unknown recipe flavor "
            + repr(args.flavor)
            + "; available: "
            + ", ".join(["public", *valid_flavors, "all"])
        )

    if args.frontend == "all":
        frontend_set = {"acp", "run", "js"}
    elif args.frontend == "all-native":
        frontend_set = {"acp", "run"}
    elif args.frontend == "all-js":
        frontend_set = {"js"}
    else:
        frontend_set = {args.frontend}

    candidates = []
    for row in rows:
        if row["platform"] not in ("any", args.platform):
            continue
        if row["section"] == "general":
            candidates.append(row)
            continue
        if row["section"] != "special":
            raise SystemExit("unknown recipe section: " + repr(row["section"]))
        if row["frontend"] not in frontend_set:
            continue
        if args.flavor == "all" or row["flavor"] in ("*", args.flavor):
            candidates.append(row)

    candidates.sort(key=lambda row: int(row["order"]))
    if not candidates:
        raise SystemExit(f"no recipe rows for {args.flavor}/{args.frontend}/{args.platform}")

    selected_by_key: dict[str, dict[str, str]] = {}
    for row in candidates:
        key = row["key"]
        previous = selected_by_key.get(key)
        if previous is None:
            selected_by_key[key] = row
            continue
        identity = ("scope", "package", "alias", "platform", "runtime_key")
        if any(previous[field] != row[field] for field in identity):
            raise SystemExit(
                "ambiguous recipe key "
                + repr(key)
                + ": "
                + repr(previous)
                + " vs "
                + repr(row)
            )
    selected = sorted(selected_by_key.values(), key=lambda row: int(row["order"]))

    imports = []
    seen_imports = set()
    coverage_mode = args.frontend in ("all", "all-native", "all-js")
    for row in selected:
        include = row["scope"] in ("base", "core") or (
            coverage_mode and row["scope"] == "host"
        )
        if not include:
            continue
        entry = f'  "{row["package"]}" @{row["alias"]},'
        if entry not in seen_imports:
            seen_imports.add(entry)
            imports.append(entry)

    pkg = PKG_TEMPLATE.read_text(encoding="utf-8")
    pkg = pkg.replace("__RECIPE_IMPORTS__", "\n".join(imports))
    PKG_OUT.write_text(pkg, encoding="utf-8")

    runtime_rows = [row for row in selected if row["scope"] in ("core", "host")]

    runtime_keys = []
    seen_runtime_keys = set()
    for row in runtime_rows:
        if row["scope"] != "core":
            continue
        runtime_key = row["runtime_key"] or row["key"]
        if runtime_key not in seen_runtime_keys:
            seen_runtime_keys.add(runtime_key)
            runtime_keys.append(runtime_key)

    recipe_items = "\n".join(f'  "{key}",' for key in runtime_keys)
    package_items = "\n".join(
        f'    ("{row["key"]}", "{row["package"]}"),' for row in runtime_rows
    )

    cases = []
    for key in runtime_keys:
        case = CASES.get(key)
        if case is None:
            raise SystemExit(
                f"no MoonBit constructor registered for core recipe runtime key: {key}"
            )
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
    print("sources: " + ", ".join(str(path) for path in sources))
    print("general:")
    for row in selected:
        if row["section"] == "general":
            print(f"  {row['order']:>3}  {row['key']:<18} {row['package']}")
    print("special:")
    for row in selected:
        if row["section"] == "special":
            print(
                f"  {row['order']:>3}  {row['flavor']}/{row['frontend']:<12} "
                f"{row['key']:<18} {row['package']}"
            )
    return 0

if __name__ == "__main__":
    sys.exit(main())
