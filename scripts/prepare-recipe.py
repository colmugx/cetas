#!/usr/bin/env python3
import argparse, csv, os, pathlib, platform as host_platform, re, sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE_RECIPES = ROOT / "composition" / "recipes.csv"

HOSTS = {
    "acp": ROOT / "cetas-acp",
    "run": ROOT / "cetas-run",
    "js": ROOT / "cetas-js",
}

RECIPE_MOD_BEGIN = "  // recipe-deps:begin"
RECIPE_MOD_END = "  // recipe-deps:end"
RECIPE_PKG_BEGIN = "  // recipe-imports:begin"
RECIPE_PKG_END = "  // recipe-imports:end"

PUBLIC_FORBIDDEN_PACKAGES = {
    "colmugx/posoco-ext-nowledge-mem",
    "colmugx/posoco-ext-obsidian",
    "colmugx/posoco-ext-zcode",
}

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

MODULE_NAME = re.compile(r'(?m)^name\s*=\s*"([^"]+)"')
MODULE_VERSION = re.compile(r'(?m)^version\s*=\s*"([^"]+)"')


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


def local_modules() -> list[tuple[str, str]]:
    paths = list(ROOT.glob("*/moon.mod"))
    extension = ROOT / "extension"
    if extension.is_dir():
        paths.extend(extension.glob("*/moon.mod"))
    modules: list[tuple[str, str]] = []
    for path in paths:
        text = path.read_text(encoding="utf-8")
        name = MODULE_NAME.search(text)
        version = MODULE_VERSION.search(text)
        if name is not None and version is not None:
            modules.append((name.group(1), version.group(1)))
    return modules


def module_for_package(
    package: str,
    modules: list[tuple[str, str]],
) -> tuple[str, str]:
    matches = [
        (name, version)
        for name, version in modules
        if package == name or package.startswith(name + "/")
    ]
    if not matches:
        raise SystemExit(
            "recipe package has no local moon.mod metadata: "
            + package
            + " (initialize/update the extension workspace first)"
        )
    matches.sort(key=lambda item: len(item[0]), reverse=True)
    return matches[0]


def replace_marked(
    path: pathlib.Path,
    begin: str,
    end: str,
    body: list[str],
) -> None:
    text = path.read_text(encoding="utf-8")
    start = text.find(begin)
    finish = text.find(end)
    if start < 0 or finish < 0 or finish < start:
        raise SystemExit(
            f"{path} is missing generated-region markers {begin!r} / {end!r}"
        )
    finish += len(end)
    replacement = "\n".join([begin, *body, end])
    path.write_text(text[:start] + replacement + text[finish:], encoding="utf-8")


def select_rows(
    rows: list[dict[str, str]],
    flavor: str,
    frontend: str,
    platform: str,
) -> list[dict[str, str]]:
    valid_flavors = sorted({
        row["flavor"]
        for row in rows
        if row["section"] == "special" and row["flavor"] != "*"
    })
    if flavor != "all" and flavor not in valid_flavors and flavor != "public":
        raise SystemExit(
            "unknown recipe flavor "
            + repr(flavor)
            + "; available: "
            + ", ".join(["public", *valid_flavors, "all"])
        )

    candidates = []
    for row in rows:
        if row["platform"] not in ("any", platform):
            continue
        if row["section"] == "general":
            candidates.append(row)
            continue
        if row["section"] != "special":
            raise SystemExit("unknown recipe section: " + repr(row["section"]))
        if row["frontend"] != frontend:
            continue
        if flavor == "all" or row["flavor"] in ("*", flavor):
            candidates.append(row)

    candidates.sort(key=lambda row: int(row["order"]))
    if not candidates:
        raise SystemExit(f"no recipe rows for {flavor}/{frontend}/{platform}")

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

    if flavor == "public":
        forbidden = [
            row for row in selected
            if row["key"] in ("nmem", "obsidian", "zcode")
            or row["package"] in PUBLIC_FORBIDDEN_PACKAGES
        ]
        if forbidden:
            details = ", ".join(
                f'{row["key"]}={row["package"]}' for row in forbidden
            )
            raise SystemExit(
                "public recipe must not include private extensions: " + details
            )
    return selected


def render_zcode_builder(selected: list[dict[str, str]]) -> str:
    enabled = any(row["key"] == "zcode" for row in selected)
    if not enabled:
        return '''fn build_compiled_zcode_ext(
  env~ : (String) -> String?,
  exists~ : async (String) -> Bool,
) -> &@posoco.Extension? {
  let _ = env
  let _ = exists
  None
}'''
    return '''async fn build_compiled_zcode_ext(
  env~ : (String) -> String?,
  exists~ : async (String) -> Bool,
) -> &@posoco.Extension? {
  match @zcode.zcode_ext_if_detected(env~, exists~) catch {
    _ => None
  } {
    Some(ext) => Some(ext as &@posoco.Extension)
    None => None
  }
}'''


def generated_mbt(
    flavor: str,
    frontend: str,
    platform: str,
    selected: list[dict[str, str]],
) -> str:
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
                f"no MoonBit constructor registered for recipe runtime key: {key}"
            )
        cases.append(case)

    zcode_builder = ""
    if frontend in ("acp", "js"):
        zcode_builder = render_zcode_builder(selected)
    tool_names_block = ""
    if frontend == "js":
        tool_names_block = '''///|
fn cetas_tool_names() -> Array[String] {
  if shell_platform_is_windows() {
    [
      "read", "write", "edit", "glob", "grep", "astgrep", "ps1", "webfetch", "ask_question",
    ]
  } else {
    [
      "read", "write", "edit", "glob", "grep", "astgrep", "bash", "webfetch", "ask_question",
    ]
  }
}

'''

    return f'''///|
/// GENERATED by scripts/prepare-recipe.py — do not edit.
/// flavor={flavor} frontend={frontend} platform={platform}
let compiled_recipe : Array[String] = [
{recipe_items}
]

///|
let compiled_recipe_packages : Map[String, String] = Map::from_array([
{package_items}
])

///|
fn compiled_target_os() -> String {{
  "{platform}"
}}

///|
fn shell_platform_is_windows() -> Bool {{
  compiled_target_os() == "windows"
}}

///|
fn canonical_cetas_tool_name(name : String) -> String {{
  if shell_platform_is_windows() && name == "bash" {{
    "ps1"
  }} else {{
    name
  }}
}}
{tool_names_block}
///|
fn build_cetas_tools(
  ctx~ : @cetas_core.HostContext,
  names : Array[String],
) -> Array[&@posoco.Extension] raise @posoco.CompositionError {{
  let anchor = @devkit.WorkspaceAnchor::WorkspaceAnchor(ctx.cwd)
  let freshness = @devkit.FreshnessGuard::FreshnessGuard()
  let exts : Array[&@posoco.Extension] = []
  let seen : Set[String] = Set([])
  for requested in names {{
    let name = canonical_cetas_tool_name(requested)
    if seen.contains(name) {{
      continue
    }}
    seen.add(name)
    match name {{
      "read" =>
        exts.push(
          @read.ReadTools(freshness~, anchor=Some(anchor), fs=Some(ctx.fs))
          as &@posoco.Extension,
        )
      "write" =>
        exts.push(
          @write.WriteTools(freshness~, anchor=Some(anchor))
          as &@posoco.Extension,
        )
      "edit" =>
        exts.push(
          @edit.EditTools(freshness~, anchor=Some(anchor))
          as &@posoco.Extension,
        )
      "glob" =>
        exts.push(@glob.GlobTools(anchor=Some(anchor)) as &@posoco.Extension)
      "grep" =>
        exts.push(@grep.GrepTools(anchor=Some(anchor)) as &@posoco.Extension)
      "astgrep" =>
        exts.push(
          @astgrep.AstGrepTools(anchor=Some(anchor)) as &@posoco.Extension,
        )
      "bash" =>
        exts.push(@bash.ShellTools(anchor=Some(anchor)) as &@posoco.Extension)
      "ps1" =>
        if shell_platform_is_windows() {{
          exts.push(
            @ps1.PowerShellTools(anchor=Some(anchor)) as &@posoco.Extension,
          )
        }} else {{
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="cetas.tools",
            detail="tool 'ps1' is unavailable in the Unix Cetas build",
          )
        }}
      "webfetch" =>
        exts.push(@webfetch.WebFetchTools() as &@posoco.Extension)
      "ask_question" =>
        exts.push(@askquestion.AskQuestionTools() as &@posoco.Extension)
      _ =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="cetas.tools",
          detail="tool '" +
            requested +
            "' is not in the canonical Cetas tool registry",
        )
    }}
  }}
  exts
}}

///|
fn cetas_skills_config() -> @skills.SkillsConfig {{
  {{ ..@skills.SkillsConfig::default(), max_instruction_chars: 65536, }}
}}

///|
async fn build_cetas_skills(
  ctx~ : @cetas_core.HostContext,
  requested? : Array[String]? = None,
) -> &@posoco.Extension? raise @posoco.CompositionError {{
  let discovered : @skills.SkillCatalog = match
    @skills.Skills::discover(
      ctx.fs,
      cwd=ctx.cwd,
      home=ctx.home,
      config=cetas_skills_config(),
    ) {{
    Some(skills) => skills.catalog()
    None => @skills.SkillCatalog::empty()
  }}
  let full = @skills.merge_builtin_skills(
    discovered,
    @forme.builtin_manual_skills(),
  )
  let catalog = match requested {{
    None => full
    Some(names) if names.is_empty() => full
    Some(names) => {{
      let selected : Array[@skills.SkillDescriptor] = []
      for name in names {{
        match full.find(name) {{
          Some(skill) => selected.push(skill)
          None =>
            raise @posoco.CompositionError::ManifestSchemaError(
              manifest_id="cetas.skills",
              detail="unknown skill '" +
                name +
                "' (available: " +
                full.names().join(", ") +
                ")",
            )
        }}
      }}
      @skills.SkillCatalog::{{ skills: selected, diagnostics: [], }}
    }}
  }}
  match
    @skills.Skills::from_catalog(ctx.fs, catalog~, config=cetas_skills_config()) {{
    Ok(skills) => Some(skills as &@posoco.Extension)
    Err(reason) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas.skills",
        detail="skills composition failed: " + reason,
      )
  }}
}}

///|
{zcode_builder}

///|
async fn build_compiled_recipe_features(
  ctx~ : @cetas_core.HostContext,
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
            manifests=["cetas.recipe"],
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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--flavor", default=os.environ.get("CETAS_FLAVOR", "public"))
    ap.add_argument("--frontend", required=True, choices=[*sorted(HOSTS), "all"])
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
    modules = local_modules()
    frontends = sorted(HOSTS) if args.frontend == "all" else [args.frontend]

    print("sources: " + ", ".join(str(path) for path in sources))
    for frontend in frontends:
        selected = select_rows(rows, args.flavor, frontend, args.platform)
        dependency_rows = [
            row for row in selected if row["scope"] in ("core", "host")
        ]

        module_imports = []
        seen_modules = set()
        for row in dependency_rows:
            module, version = module_for_package(row["package"], modules)
            if module in seen_modules:
                continue
            seen_modules.add(module)
            module_imports.append(f'  "{module}@{version}",')

        package_imports = []
        seen_packages = set()
        for row in dependency_rows:
            package = row["package"]
            if package in seen_packages:
                continue
            seen_packages.add(package)
            package_imports.append(f'  "{package}" @{row["alias"]},')

        host = HOSTS[frontend]
        replace_marked(
            host / "moon.mod",
            RECIPE_MOD_BEGIN,
            RECIPE_MOD_END,
            module_imports,
        )
        replace_marked(
            host / "lib" / "moon.pkg",
            RECIPE_PKG_BEGIN,
            RECIPE_PKG_END,
            package_imports,
        )
        (host / "lib" / "recipe.generated.mbt").write_text(
            generated_mbt(args.flavor, frontend, args.platform, selected),
            encoding="utf-8",
        )

        print(f"recipe: {args.flavor}/{frontend}/{args.platform}")
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
        print("modules:")
        for item in module_imports:
            print(item.strip().rstrip(","))
    return 0


if __name__ == "__main__":
    sys.exit(main())
