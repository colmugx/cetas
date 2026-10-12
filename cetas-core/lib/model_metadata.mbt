///|
pub struct FileModelMetadataStore {
  priv fs : &@workspace.WorkspaceFs
  priv home : String
}

///|
pub fn FileModelMetadataStore::FileModelMetadataStore(
  fs : &@workspace.WorkspaceFs,
  home~ : String,
) -> FileModelMetadataStore {
  { fs, home, }
}

///|
pub extend FileModelMetadataStore with @llm.ModelMetadataStore::{read, write}

///|
pub impl @llm.ModelMetadataStore for FileModelMetadataStore with fn read(
  self : FileModelMetadataStore,
) -> Json? {
  match
    @workspace.read_file_result(
      self.fs,
      cetas_dir(self.home) + "/models_dev.json",
    ) {
    Missing => None
    Failed(message) => fail(message)
    Content(text) => Some(@json.parse(text))
  }
}

///|
pub impl @llm.ModelMetadataStore for FileModelMetadataStore with fn write(
  self : FileModelMetadataStore,
  payload : Json,
) -> Unit {
  let dir = cetas_dir(self.home)
  self.fs.mkdir(dir, recursive=true)
  self.fs.write_file_atomic(
    dir + "/models_dev.json",
    payload.stringify(indent=2) + "\n",
  )
}
