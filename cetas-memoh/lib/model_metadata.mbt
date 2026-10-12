///|
priv struct MemohModelMetadataStore {
  fs : &@workspace.WorkspaceFs
  home : String
}

///|
impl @llm.ModelMetadataStore for MemohModelMetadataStore with fn read(
  self : MemohModelMetadataStore,
) -> Json? {
  match
    @workspace.read_file_result(self.fs, self.home + "/.cetas/models_dev.json") {
    Missing => None
    Failed(message) => fail(message)
    Content(text) => Some(@json.parse(text))
  }
}

///|
impl @llm.ModelMetadataStore for MemohModelMetadataStore with fn write(
  self : MemohModelMetadataStore,
  payload : Json,
) -> Unit {
  let dir = self.home + "/.cetas"
  self.fs.mkdir(dir, recursive=true)
  self.fs.write_file_atomic(
    dir + "/models_dev.json",
    payload.stringify(indent=2) + "\n",
  )
}
