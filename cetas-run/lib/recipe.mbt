///|
/// Public run composition. Keys and packages come from the Cetas roster in
/// cetas-core, so this surface cannot drift from the other hosts' inventory.
let compiled_recipe : Array[String] = @cetas_core.cetas_recipe_keys("run")

///|
let compiled_recipe_packages : Map[String, String] = @cetas_core.cetas_capability_packages(
  "run",
)

///|
#cfg(platform="windows")
fn compiled_target_os() -> String {
  "windows"
}

///|
#cfg(all(not(target="js"), not(platform="windows")))
fn compiled_target_os() -> String {
  "unix"
}

///|
fn shell_platform_is_windows() -> Bool {
  compiled_target_os() == "windows"
}

///|
fn canonical_cetas_tool_name(name : String) -> String {
  if shell_platform_is_windows() && name == "bash" {
    "ps1"
  } else {
    name
  }
}

///|
fn build_cetas_tools(
  ctx~ : @cetas_core.HostContext,
  names : Array[String],
  host_group~ : @async.TaskGroup[Unit]? = None,
) -> Array[&@posoco.Extension] raise @posoco.CompositionError {
  let anchor = @devkit.WorkspaceAnchor::WorkspaceAnchor(ctx.cwd)
  let freshness = @devkit.FreshnessGuard::FreshnessGuard()
  let exts : Array[&@posoco.Extension] = []
  let seen : Set[String] = Set([])
  for requested in names {
    let name = canonical_cetas_tool_name(requested)
    if seen.contains(name) {
      continue
    }
    seen.add(name)
    match name {
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
          @edit.EditTools(freshness~, anchor=Some(anchor)) as &@posoco.Extension,
        )
      "glob" =>
        exts.push(@glob.GlobTools(anchor=Some(anchor)) as &@posoco.Extension)
      "grep" =>
        exts.push(@grep.GrepTools(anchor=Some(anchor)) as &@posoco.Extension)
      "astgrep" =>
        exts.push(
          @astgrep.AstGrepTools(anchor=Some(anchor)) as &@posoco.Extension,
        )
      "bash" => {
        let shell = @bash.ShellTools(anchor=Some(anchor))
        match host_group {
          Some(group) => shell.attach(group)
          None => ()
        }
        exts.push(shell as &@posoco.Extension)
      }
      "ps1" =>
        if shell_platform_is_windows() {
          exts.push(
            @ps1.PowerShellTools(anchor=Some(anchor)) as &@posoco.Extension,
          )
        } else {
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="cetas.tools",
            detail="tool 'ps1' is unavailable in the Unix Cetas build",
          )
        }
      "webfetch" => exts.push(@webfetch.WebFetchTools() as &@posoco.Extension)
      "ask_question" =>
        exts.push(@askquestion.AskQuestionTools() as &@posoco.Extension)
      _ =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="cetas.tools",
          detail="tool '" +
            requested +
            "' is not in the canonical Cetas tool registry",
        )
    }
  }
  exts
}

///|
fn cetas_skills_config() -> @skills.SkillsConfig {
  {
    ..@skills.SkillsConfig::default(),
    max_instruction_chars: @cetas_core.cetas_skills_max_instruction_chars(),
  }
}

///|
async fn build_cetas_skills(
  ctx~ : @cetas_core.HostContext,
  manuals~ : Array[@skills.SkillDescriptor],
  requested~ : Array[String]? = None,
) -> &@posoco.Extension? raise @posoco.CompositionError {
  let discovered : @skills.SkillCatalog = match
    @skills.Skills::discover(
      ctx.fs,
      cwd=ctx.cwd,
      home=ctx.home,
      config=cetas_skills_config(),
    ) {
    Some(skills) => skills.catalog()
    None => @skills.SkillCatalog::empty()
  }
  let full = @skills.merge_builtin_skills(discovered, manuals)
  let catalog = match requested {
    None => full
    Some(names) if names.is_empty() => full
    Some(names) => {
      let selected : Array[@skills.SkillDescriptor] = []
      for name in names {
        match full.find(name) {
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
        }
      }
      @skills.SkillCatalog::{ skills: selected, diagnostics: [], }
    }
  }
  match
    @skills.Skills::from_catalog(ctx.fs, catalog~, config=cetas_skills_config()) {
    Ok(skills) => Some(skills as &@posoco.Extension)
    Err(reason) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="cetas.skills",
        detail="skills composition failed: " + reason,
      )
  }
}

///|

///|
async fn build_compiled_recipe_features(
  ctx~ : @cetas_core.HostContext,
  host_group~ : @async.TaskGroup[Unit]? = None,
  profile_activation_sink~ : &@profiles.ProfileActivationSink? = None,
  host_help_note~ : String? = None,
  host_version_note~ : String? = None,
  obsidian_vault~ : String? = None,
) -> Array[&@posoco.Extension] raise @posoco.CompositionError {
  let _ = obsidian_vault
  let exts : Array[&@posoco.Extension] = []
  let episodic : Array[&@posoco.Extension] = []
  let anchor = @devkit.WorkspaceAnchor::WorkspaceAnchor(ctx.cwd)
  let freshness = @devkit.FreshnessGuard::FreshnessGuard()
  // One Forme value feeds both surfaces: the /help command and the builtin
  // manuals merged into the skills catalog below.
  let forme = @forme.Forme::Forme(
    host_note=host_help_note,
    version_note=host_version_note,
  )
  for key in compiled_recipe {
    match key {
      "forme" => exts.push(forme as &@posoco.Extension)
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
          @edit.EditTools(freshness~, anchor=Some(anchor)) as &@posoco.Extension,
        )
      "glob" =>
        exts.push(@glob.GlobTools(anchor=Some(anchor)) as &@posoco.Extension)
      "grep" =>
        exts.push(@grep.GrepTools(anchor=Some(anchor)) as &@posoco.Extension)
      "astgrep" =>
        exts.push(
          @astgrep.AstGrepTools(anchor=Some(anchor)) as &@posoco.Extension,
        )
      "webfetch" =>
        episodic.push(@webfetch.WebFetchTools() as &@posoco.Extension)
      "shell" =>
        for shell in build_cetas_tools(ctx~, ["bash"], host_group~) {
          exts.push(shell)
        }
      "skills" => {
        let skills = build_cetas_skills(
          ctx~,
          manuals=forme.builtin_manual_skills(),
        ) catch {
          _ => None
        }
        match skills {
          Some(skills) => exts.push(skills)
          None => ()
        }
      }
      "askquestion" =>
        exts.push(@askquestion.AskQuestionTools() as &@posoco.Extension)
      "handoff" =>
        exts.push(
          @handoff.Handoff(
            cwd=ctx.cwd,
            store=@handoff.DefaultHandoffStore() as &@handoff.HandoffStore,
            probe=@handoff.HandoffWorkspaceState(ctx.cwd)
              as &@handoff.HandoffWorkspaceProbe,
            work_sources=[],
          )
          as &@posoco.Extension,
        )
      "lazytools" => ()
      _ =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="cetas.recipe",
          detail="compiled recipe key has no constructor: " + key,
        )
    }
  }

  // Profiles must be present even with no manifests: /profile save is how a
  // user creates their first profile, and must never be an inert command.
  // Keep LazyTools in charge of deferred tools in both cases.
  let manifests = @cetas_core.load_cetas_profiles(
    ctx.fs,
    home=ctx.home,
    cwd=ctx.cwd,
  ) catch {
    _ => []
  }
  if compiled_recipe_packages.get("lazytools") is Some(_) {
    match
      @profiles.compose_profiles(
        resident=exts,
        deferred=episodic,
        manifests~,
        activation_sink=profile_activation_sink,
        store=Some(
          @cetas_core.CetasProfileStore(ctx.fs, home=ctx.home, cwd=ctx.cwd),
        ),
      ) {
      Ok(composition) => return composition.exts
      Err(message) =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="cetas.profiles",
          detail=message,
        )
    }
  } else if !manifests.is_empty() {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="cetas.recipe",
      detail="profile composition requires lazytools",
    )
  }

  match compiled_recipe_packages.get("lazytools") {
    Some(_) =>
      match @lazytools.LazyTools::defer_extensions(exts=episodic) {
        Ok((gateway, views)) => {
          for view in views {
            exts.push(view)
          }
          exts.push(gateway as &@posoco.Extension)
        }
        Err(message) =>
          raise @posoco.CompositionError::ToolCollision(
            "deferred tool name collision",
            message,
            manifests=["cetas.recipe"],
          )
      }
    None =>
      if !episodic.is_empty() {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="cetas.recipe",
          detail="recipe has episodic extensions but no lazytools entry",
        )
      }
  }
  exts
}
