///|
test "project name uses only the last path segment" {
  assert_eq(project_name("/work/team/cetas"), "cetas")
  assert_eq(project_name("C:\\work\\team\\cetas"), "cetas")
  assert_eq(project_name("/"), "workspace")
}

///|
test "team names trim controls and keep defaults for blanks" {
  let names = TeamNames::from_json({
    "refiner": "  Ada\n",
    "rd": "",
    "set": "Grace",
    "te": "  Linus  ",
  })
  assert_eq(names.refiner, "Ada")
  assert_eq(names.rd, "RD")
  assert_eq(names.set, "Grace")
  assert_eq(names.te, "Linus")
}

///|
test "role prompt carries the customized name" {
  assert_true(refiner_system_prompt("Ada").contains("Ada"))
  assert_true(development_system_prompt("Grace", "SET").contains("Grace"))
  assert_true(development_system_prompt("Grace", "SET").contains("SET"))
}
