///|
/// Public console composition. Keys and packages come from the Cetas roster in
/// cetas-core, so this surface cannot drift from the other hosts' inventory.
let compiled_recipe : Array[String] = @cetas_core.cetas_recipe_keys("native")

///|
let compiled_recipe_packages : Map[String, String] = @cetas_core.cetas_capability_packages(
  "native",
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
  question~ : &@askquestion.QuestionEndpoint? = None,
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
        match question {
          // Child face: the answerer is the spawning parent agent, through the
          // subagent extension's question channel.
          Some(endpoint) =>
            exts.push(
              @askquestion.AskQuestionTools::for_parent(endpoint~)
              as &@posoco.Extension,
            )
          None =>
            exts.push(@askquestion.AskQuestionTools() as &@posoco.Extension)
        }
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
  askquestion~ : @askquestion.AskQuestionTools? = None,
) -> Array[&@posoco.Extension] raise @posoco.CompositionError {
  let exts : Array[&@posoco.Extension] = []
  let episodic : Array[&@posoco.Extension] = []
  let anchor = @devkit.WorkspaceAnchor::WorkspaceAnchor(ctx.cwd)
  let freshness = @devkit.FreshnessGuard::FreshnessGuard()

  for key in compiled_recipe {
    match key {
      "forme" =>
        exts.push(
          @forme.Forme::Forme(host_note=host_help_note) as &@posoco.Extension,
        )
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
          manuals=@forme.Forme::Forme().builtin_manual_skills(),
        ) catch {
          _ => None
        }
        match skills {
          Some(skills) => exts.push(skills)
          None => ()
        }
      }
      "askquestion" =>
        // The native projection subscribes to this instance before the agent
        // exists, so the non-blocking question lifecycle reaches the terminal;
        // the default console keeps constructing its own unobserved instance.
        exts.push(
          match askquestion {
            Some(tools) => tools as &@posoco.Extension
            None => @askquestion.AskQuestionTools() as &@posoco.Extension
          },
        )
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

  // Locally provided tools, if any: the public build contributes none, so this
  // is a no-op unless the local build swapped `cetas-extras`.
  for ext in @extras.deferred_extensions(host_group) {
    episodic.push(ext)
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
