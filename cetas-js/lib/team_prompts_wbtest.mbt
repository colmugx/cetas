///|
test "project name uses only the last path segment" {
  assert_eq(project_name("/work/team/cetas"), "cetas")
  assert_eq(project_name("C:\\work\\team\\cetas"), "cetas")
  assert_eq(project_name("/"), "workspace")
}

///|
test "team names trim controls and keep defaults for blanks" {
  let names = TeamNames::from_json({
    "po": "  Ada\n",
    "rd": "",
    "set": "Grace",
    "te": "  Linus  ",
  })
  assert_eq(names.po, "Ada")
  assert_eq(names.rd, "RD")
  assert_eq(names.set, "Grace")
  assert_eq(names.te, "Linus")
}

///|
test "role prompt carries the customized name" {
  assert_true(po_system_prompt("Ada").contains("Ada"))
  assert_true(
    development_system_prompt("Grace", "SET", WorkProfile::software()).contains(
      "Grace",
    ),
  )
  assert_true(
    development_system_prompt("Grace", "SET", WorkProfile::software()).contains(
      "SET",
    ),
  )
}

///|
test "team mcp settings round-trip per role" {
  let mcp = default_team_mcp()
  mcp["rd"] = {
    enabled: true,
    all: false,
    servers: ["github", "browser"],
    tools: ["github__create_issue"],
  }
  let parsed = TeamMcp::from_json_map(TeamMcp::to_json_map(mcp))
  match parsed.get("rd") {
    Some(value) => {
      assert_true(value.enabled)
      assert_false(value.all)
      assert_eq(value.servers, ["github", "browser"])
      assert_eq(value.tools, ["github__create_issue"])
    }
    None => fail("rd MCP settings missing")
  }
  assert_false(parsed["te"].enabled)
}

///|
test "team skill settings round-trip per role" {
  let skills = default_team_skills()
  skills["te"] = { enabled: true, all: false, skills: ["tdd"], }
  let parsed = TeamSkills::from_json_map(TeamSkills::to_json_map(skills))
  match parsed.get("te") {
    Some(value) => {
      assert_true(value.enabled)
      assert_false(value.all)
      assert_eq(value.skills, ["tdd"])
    }
    None => fail("te skill settings missing")
  }
  assert_false(parsed["rd"].enabled)
}

///|
test "team config round-trips names, mcp, skills and profile" {
  let mcp = default_team_mcp()
  mcp["te"] = { enabled: true, all: false, servers: ["browser"], tools: [], }
  let skills = default_team_skills()
  skills["rd"] = { enabled: true, all: false, skills: ["tdd"], }
  let config : TeamConfig = {
    names: { ..TeamNames::defaults(), rd: "R&D", },
    mcp,
    skills,
    profile: WorkProfile::document(),
  }
  let parsed = TeamConfig::from_json(config.to_json())
  assert_eq(parsed.names.rd, "R&D")
  assert_eq(parsed.profile.id, "document")
  assert_eq(parsed.mcp["te"].servers, ["browser"])
  assert_eq(parsed.skills["rd"].skills, ["tdd"])
}
